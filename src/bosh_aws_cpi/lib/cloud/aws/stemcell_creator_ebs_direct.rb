module Bosh::AwsCloud
  # =============================================================================
  # DESIGN SKETCH -- NOT WIRED IN, NOT TESTED AGAINST AWS.
  # =============================================================================
  #
  # Alternative to StemcellCreator#create_via_import_snapshot (see branch
  # bosh-2024-import-snapshot-fix). Instead of handing root.img to AWS VM
  # Import/Export, this builds an EBS snapshot directly by writing the raw
  # image blocks via the EBS Direct APIs, then registers an AMI from it.
  #
  # This mirrors what the classic StemcellCreator#create does (dd root.img onto
  # an attached EBS volume, snapshot it, register AMI) but WITHOUT needing to
  # run on an EC2 instance -- so it works from a create-env container.
  #
  # See the commit message for the full rationale and trade-offs vs
  # ImportSnapshot. The two big wins: no image-format conversion (raw bytes go
  # in verbatim, so a BOSH root.img can't be rejected the way ImportSnapshot
  # may reject non-VMDK/VHD input) and no vmimport role / S3 staging bucket.
  #
  # Prerequisites before this could be used for real:
  #   * add `aws-sdk-ebs` to bosh_aws_cpi.gemspec and bundle install
  #     (Aws::EBS::Client is NOT part of aws-sdk-ec2);
  #   * IAM: ebs:StartSnapshot, ebs:PutSnapshotBlock, ebs:CompleteSnapshot,
  #     ec2:RegisterImage, and (if encrypting) kms:GenerateDataKey* on the key;
  #   * validate end-to-end that the registered AMI actually BOOTS.
  #
  class StemcellCreatorEbsDirect
    include Bosh::Exec
    include Helpers

    # EBS Direct requires a fixed block size of 512 KiB for every block except
    # (optionally) the last. This is an AWS API constraint, not a tunable.
    EBS_BLOCK_SIZE = 512 * 1024

    # Snapshots created via EBS Direct must declare their volume size in whole
    # GiB. root.img is padded up to the next GiB boundary with zero blocks
    # (which are simply not written -- absent blocks read back as zeros).
    GIB = 1024 * 1024 * 1024

    # Bound the PutSnapshotBlock fan-out. Each block is one HTTPS call; a multi-GB
    # image is thousands of them, so we parallelise but cap concurrency to stay
    # well under EBS Direct request-rate limits.
    PUT_BLOCK_CONCURRENCY = 16

    attr_reader :resource

    def initialize(resource, stemcell_props, ebs_client:)
      @resource = resource
      @stemcell_props = stemcell_props
      @ebs_client = ebs_client
      @creation_tags = nil
    end

    # Container-friendly heavy-stemcell creation via EBS Direct APIs.
    #
    # @param image_path [String] local path to the stemcell .tgz
    # @param kms_key_arn [String, nil] optional CMK to encrypt the snapshot
    # @param tags [Hash, nil] optional string-key tag hash
    # @return [Stemcell]
    def create_via_ebs_direct(image_path, kms_key_arn: nil, tags: nil)
      @creation_tags = TagManager.tags_hash(tags)

      Dir.mktmpdir('bosh-stemcell-ebs') do |dir|
        root_img = File.join(dir, 'root.img')
        extract_root_image(image_path, root_img)

        size_bytes = File.size(root_img)
        volume_gib = (size_bytes.to_f / GIB).ceil
        volume_gib = 1 if volume_gib < 1

        snapshot_id = build_snapshot(root_img, size_bytes, volume_gib, kms_key_arn)
        tag_snapshot(snapshot_id)
        register_image_from_snapshot(snapshot_id)
      end
    end

    private

    # argv form -- no shell, no interpolation (contrast with the ImportSnapshot
    # sketch which shelled out "tar ... > file" and was command-injection prone).
    def extract_root_image(image_path, dest_path)
      logger.info("extracting root image from #{image_path}")
      File.open(dest_path, 'wb') do |out|
        # Bosh::Exec.sh accepts an argv array; capture stdout to the file.
        result = sh(['tar', '-xzf', image_path, '-O', 'root.img'], output_to: out)
        logger.debug("tar exit ok: #{result.success?}")
      end
    rescue Bosh::Exec::Error => e
      raise Bosh::Clouds::CloudError, "Unable to extract stemcell root image: #{e.message}\nScript output:\n#{e.output}"
    end

    # StartSnapshot -> PutSnapshotBlock (xN, parallel) -> CompleteSnapshot.
    def build_snapshot(root_img, size_bytes, volume_gib, kms_key_arn)
      start_params = {
        volume_size: volume_gib,
        description: 'BOSH stemcell (EBS Direct)',
        # Client token gives idempotency if the whole op is retried.
        client_token: SecureRandom.uuid,
      }
      unless kms_key_arn.nil? || kms_key_arn.empty?
        start_params[:encrypted] = true
        start_params[:kms_key_arn] = kms_key_arn
      end

      logger.info("StartSnapshot (#{volume_gib} GiB) for stemcell root image")
      snapshot = @ebs_client.start_snapshot(start_params)
      snapshot_id = snapshot.snapshot_id

      block_count = put_all_blocks(snapshot_id, root_img, size_bytes)

      logger.info("CompleteSnapshot '#{snapshot_id}' (#{block_count} blocks written)")
      @ebs_client.complete_snapshot(
        snapshot_id: snapshot_id,
        changed_blocks_count: block_count,
      )

      wait_for_snapshot_completed(snapshot_id)
      snapshot_id
    rescue Aws::Errors::ServiceError => e
      raise Bosh::Clouds::CloudError, "EBS Direct snapshot build failed: #{e.message}"
    end

    # Reads root.img in 512 KiB blocks and PUTs each non-zero block. Zero blocks
    # are skipped -- unwritten blocks read back as zeros, so this both saves API
    # calls and lets a small root.img describe a larger padded volume.
    #
    # Returns the number of blocks actually written (needed by CompleteSnapshot).
    def put_all_blocks(snapshot_id, root_img, size_bytes)
      written = Concurrent::AtomicFixnum.new(0) # or a Mutex-guarded counter
      pool = Bosh::ThreadPool.new(max_threads: PUT_BLOCK_CONCURRENCY, logger: logger)

      File.open(root_img, 'rb') do |f|
        index = 0
        while (chunk = f.read(EBS_BLOCK_SIZE))
          this_index = index
          data = chunk
          index += 1

          next if zero_block?(data)

          pool.process do
            put_one_block(snapshot_id, this_index, data)
            written.increment
          end
        end
        pool.wait
      end

      written.value
    ensure
      pool&.shutdown
    end

    def put_one_block(snapshot_id, index, data)
      # Last block may be short; EBS Direct requires exactly 512 KiB, so pad.
      data = data.ljust(EBS_BLOCK_SIZE, "\x00") if data.bytesize < EBS_BLOCK_SIZE

      checksum = Base64.strict_encode64(Digest::SHA256.digest(data))
      @ebs_client.put_snapshot_block(
        snapshot_id: snapshot_id,
        block_index: index,
        block_data: StringIO.new(data),
        data_length: EBS_BLOCK_SIZE,
        checksum: checksum,
        checksum_algorithm: 'SHA256',
      )
    end

    def zero_block?(data)
      # Fast path: a block that is entirely NUL bytes need not be written.
      data.each_byte.all?(&:zero?)
    end

    def wait_for_snapshot_completed(snapshot_id)
      # After CompleteSnapshot the snapshot transitions pending -> completed.
      # Reuse the existing EC2 resource waiter rather than polling EBS.
      snapshot = resource.snapshot(snapshot_id)
      ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')
    end

    def tag_snapshot(snapshot_id)
      return if @creation_tags.nil? || @creation_tags.empty?

      snapshot = resource.snapshot(snapshot_id)
      TagManager.create_tags(snapshot, @creation_tags)
    rescue Aws::EC2::Errors::TagLimitExceeded => e
      logger.error("could not tag snapshot #{snapshot_id}: #{e.message}")
    end

    # Reuses the real StemcellCreator's image_params/register flow. In a real
    # implementation this method would live on (or be shared with) StemcellCreator
    # rather than being duplicated -- kept here only to make the sketch readable.
    def register_image_from_snapshot(snapshot_id)
      creator = StemcellCreator.new(resource, @stemcell_props)
      params = creator.send(:image_params, snapshot_id)
      image_id = resource.client.register_image(params).image_id
      image = resource.images(filters: [{ name: 'image-id', values: [image_id] }]).first
      ResourceWait.for_image(image: image, state: 'available')
      Stemcell.new(resource, image)
    end

    def logger
      Bosh::Clouds::Config.logger
    end
  end
end
