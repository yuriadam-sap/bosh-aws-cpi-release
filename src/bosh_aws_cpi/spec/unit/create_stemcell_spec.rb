require "spec_helper"

describe Bosh::AwsCloud::CloudV1 do
  before { @tmp_dir = Dir.mktmpdir }
  after { FileUtils.rm_rf(@tmp_dir) }

  describe "EBS-volume based flow" do
    let(:creator) { double(Bosh::AwsCloud::StemcellCreator) }
    let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
    let(:az_selector) do
      instance_double(Bosh::AwsCloud::AvailabilityZoneSelector, select_availability_zone: "us-east-1a")
    end

    context "light stemcell" do
      let(:ami_id) { "ami-xxxxxxxx" }
      let(:encrypted_ami) { instance_double(Aws::EC2::Image, state: "available") }
      let(:stemcell_properties) do
        {
          "root_device_name" => "/dev/sda1",
          "architecture" => "x86_64",
          "name" => "stemcell-name",
          "version" => "1.2.3",
          "ami" => {
            "us-east-1" => ami_id,
          },
        }
      end

      it "should return a light stemcell" do
        cloud = mock_cloud do |ec2|
          expect(ec2).to receive(:images).with(
            filters: [{
              name: "image-id",
              values: [ami_id],
            }],
            include_deprecated: true,
          ).and_return([double("image", id: ami_id)])
        end
        expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("#{ami_id} light")
      end

      context "when encrypted flag is true" do
        let(:kms_key_arn) { nil }
        let(:stemcell_properties) do
          {
            "encrypted" => true,
            "ami" => {
              "us-east-1" => ami_id,
            },
          }
        end

        it "should copy ami" do
          cloud = mock_cloud do |ec2|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: "image-id",
                values: [ami_id],
              }],
              include_deprecated: true,
            ).and_return([double("image", id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: "us-east-1",
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn,
            ).and_return(double("copy_image_result", image_id: "ami-newami"))

            expect(ec2).to receive(:image).with("ami-newami").and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: "available",
            )
          end

          cloud.create_stemcell("/tmp/foo", stemcell_properties)
        end

        it "should return stemcell id (not light stemcell id)" do
          cloud = mock_cloud do |ec2, _client|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: "image-id",
                values: [ami_id],
              }],
              include_deprecated: true,
            ).and_return([double("image", id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: "us-east-1",
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn,
            ).and_return(double("copy_image_result", image_id: "ami-newami"))

            expect(ec2).to receive(:image).with("ami-newami").and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: "available",
            )
          end

          expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-newami")
        end
      end

      context "and kms_key_arn is given" do
        let(:kms_key_arn) { "arn:aws:kms:us-east-1:12345678:key/guid" }
        let(:stemcell_properties) do
          {
            "encrypted" => true,
            "kms_key_arn" => kms_key_arn,
            "ami" => {
              "us-east-1" => ami_id,
            },
          }
        end

        it "should encrypt ami with given kms_key_arn" do
          cloud = mock_cloud do |ec2, _client|
            expect(ec2).to receive(:images).with(
              filters: [{
                name: "image-id",
                values: [ami_id],
              }],
              include_deprecated: true,
            ).and_return([double("image", id: ami_id)])

            expect(ec2.client).to receive(:copy_image).with(
              source_region: "us-east-1",
              source_image_id: ami_id,
              name: "Copied from SourceAMI #{ami_id}",
              encrypted: true,
              kms_key_id: kms_key_arn,
            ).and_return(double("copy_image_result", image_id: "ami-newami"))

            expect(ec2).to receive(:image).with("ami-newami").and_return(encrypted_ami)

            expect(Bosh::AwsCloud::ResourceWait).to receive(:for_image).with(
              image: encrypted_ami,
              state: "available",
            )
          end

          cloud.create_stemcell("/tmp/foo", stemcell_properties)
        end
      end

      context "when ami does NOT exist" do
        it "should return error" do
          cloud = mock_cloud do |ec2|
            allow(ec2).to receive(:images).with(
              filters: [{
                name: "image-id",
                values: ["ami-xxxxxxxx"],
              }],
              include_deprecated: true,
            ).and_return([])
          end
          expect {
            cloud.create_stemcell("/tmp/foo", stemcell_properties)
          }.to raise_error(/Stemcell does not contain an AMI in region/)
        end
      end
    end

    context "heavy stemcell" do
      # Heavy stemcells no longer attach an EBS volume and shell out to
      # stemcell-copy/dd. CloudV1#create_stemcell routes them through the shared
      # #create_ami_for_stemcell seam, which writes root.img straight into an EBS
      # snapshot via StemcellCreator#create_via_ebs_direct. These specs assert
      # that delegation and that the classic path (current_vm_id / volume attach)
      # is never touched.
      let(:stemcell_properties) do
        {
          "root_device_name" => "/dev/sda1",
          "architecture" => "x86_64",
          "name" => "stemcell-name",
          "version" => "1.2.3",
          "virtualization_type" => "paravirtual",
        }
      end
      let(:stemcell) { instance_double(Bosh::AwsCloud::Stemcell, :id => "ami-xxxxxxxx") }
      let(:aws_config) do
        instance_double(Bosh::AwsCloud::AwsConfig, stemcell: {}, encrypted: false, kms_key_arn: nil)
      end
      let(:global_config) { instance_double(Bosh::AwsCloud::Config, aws: aws_config) }
      let(:stemcell_cloud_props) { Bosh::AwsCloud::StemcellCloudProps.new(stemcell_properties, global_config) }
      let(:props_factory) { instance_double(Bosh::AwsCloud::PropsFactory) }

      before do
        allow(Bosh::AwsCloud::PropsFactory).to receive(:new)
            .and_return(props_factory)
        allow(props_factory).to receive(:stemcell_props)
            .with(stemcell_properties)
            .and_return(stemcell_cloud_props)
      end

      def make_cloud(cloud_props, options = nil)
        block = lambda do |ec2|
          expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
              .with(ec2, cloud_props)
              .and_return(creator)
          allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
          allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
        end
        options ? mock_cloud(options, &block) : mock_cloud(&block)
      end

      it "should create a stemcell" do
        cloud = make_cloud(stemcell_cloud_props)

        expect(cloud).not_to receive(:current_vm_id)
        expect(volume_manager).not_to receive(:create_ebs_volume)
        expect(volume_manager).not_to receive(:attach_ebs_volume)

        expect(creator).to receive(:create_via_ebs_direct).with(
          "/tmp/foo",
          encrypted: false,
          kms_key_arn: nil,
          tags: {},
        ).and_return(stemcell)

        expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
      end

      it "sets tags to an empty Hash when no tags key is present in cloud properties" do
        expect(stemcell_cloud_props.tags).to eq({})
      end

      it "should create a stemcell forwarding tags to the creator" do
        tags = { "env" => "test", "owner" => "bosh" }
        tagged_stemcell_properties = stemcell_properties.merge("tags" => tags)
        tagged_cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(tagged_stemcell_properties, global_config)

        allow(props_factory).to receive(:stemcell_props)
            .with(tagged_stemcell_properties)
            .and_return(tagged_cloud_props)

        cloud = make_cloud(tagged_cloud_props)

        expect(cloud).not_to receive(:current_vm_id)

        expect(creator).to receive(:create_via_ebs_direct).with(
          "/tmp/foo",
          encrypted: false,
          kms_key_arn: nil,
          tags: tags,
        ).and_return(stemcell)

        expect(cloud.create_stemcell("/tmp/foo", tagged_stemcell_properties)).to eq("ami-xxxxxxxx")
      end

      context "when the CPI configuration includes a kernel_id for stemcell" do
        it "creates a stemcell" do
          options = mock_cloud_options["properties"]
          options["aws"]["stemcell"] = { "kernel_id" => "fake-kernel-id" }
          cloud = make_cloud(stemcell_cloud_props, options)

          expect(cloud).not_to receive(:current_vm_id)

          expect(creator).to receive(:create_via_ebs_direct).with(
            "/tmp/foo",
            encrypted: false,
            kms_key_arn: nil,
            tags: {},
          ).and_return(stemcell)

          expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
        end

        it "creates a stemcell forwarding tags to the creator" do
          tags = { "env" => "test", "owner" => "bosh" }
          tagged_stemcell_properties = stemcell_properties.merge("tags" => tags)
          tagged_cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(tagged_stemcell_properties, global_config)

          options = mock_cloud_options["properties"]
          options["aws"]["stemcell"] = { "kernel_id" => "fake-kernel-id" }

          allow(props_factory).to receive(:stemcell_props)
              .with(tagged_stemcell_properties)
              .and_return(tagged_cloud_props)

          cloud = make_cloud(tagged_cloud_props, options)

          expect(cloud).not_to receive(:current_vm_id)

          expect(creator).to receive(:create_via_ebs_direct).with(
            "/tmp/foo",
            encrypted: false,
            kms_key_arn: nil,
            tags: tags,
          ).and_return(stemcell)

          expect(cloud.create_stemcell("/tmp/foo", tagged_stemcell_properties)).to eq("ami-xxxxxxxx")
        end
      end

      context "when encrypted flag is set to true" do
        context "and kms_key_arn is provided" do
          let(:stemcell_properties) do
            {
              "root_device_name" => "/dev/sda1",
              "architecture" => "x86_64",
              "name" => "stemcell-name",
              "version" => "1.2.3",
              "virtualization_type" => "paravirtual",
              "encrypted" => true,
              "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
            }
          end

          it "should create stemcell forwarding the given kms key" do
            cloud = make_cloud(stemcell_cloud_props)

            expect(cloud).not_to receive(:current_vm_id)

            expect(creator).to receive(:create_via_ebs_direct).with(
              "/tmp/foo",
              encrypted: true,
              kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
              tags: {},
            ).and_return(stemcell)

            expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
          end

          it "should create stemcell forwarding the given kms key and tags to the creator" do
            tags = { "env" => "test", "owner" => "bosh" }
            tagged_stemcell_properties = stemcell_properties.merge("tags" => tags)
            tagged_cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(tagged_stemcell_properties, global_config)

            allow(props_factory).to receive(:stemcell_props)
                .with(tagged_stemcell_properties)
                .and_return(tagged_cloud_props)

            cloud = make_cloud(tagged_cloud_props)

            expect(cloud).not_to receive(:current_vm_id)

            expect(creator).to receive(:create_via_ebs_direct).with(
              "/tmp/foo",
              encrypted: true,
              kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
              tags: tags,
            ).and_return(stemcell)

            expect(cloud.create_stemcell("/tmp/foo", tagged_stemcell_properties)).to eq("ami-xxxxxxxx")
          end
        end

        context "and kms_key_arn is NOT provided" do
          let(:stemcell_properties) do
            {
              "root_device_name" => "/dev/sda1",
              "architecture" => "x86_64",
              "name" => "stemcell-name",
              "version" => "1.2.3",
              "virtualization_type" => "paravirtual",
              "encrypted" => true,
            }
          end

          it "should create an encrypted stemcell" do
            cloud = make_cloud(stemcell_cloud_props)

            expect(cloud).not_to receive(:current_vm_id)

            expect(creator).to receive(:create_via_ebs_direct).with(
              "/tmp/foo",
              encrypted: true,
              kms_key_arn: nil,
              tags: {},
            ).and_return(stemcell)

            expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
          end

          it "should create an encrypted stemcell forwarding tags to the creator" do
            tags = { "env" => "test", "owner" => "bosh" }
            tagged_stemcell_properties = stemcell_properties.merge("tags" => tags)
            tagged_cloud_props = Bosh::AwsCloud::StemcellCloudProps.new(tagged_stemcell_properties, global_config)

            allow(props_factory).to receive(:stemcell_props)
                .with(tagged_stemcell_properties)
                .and_return(tagged_cloud_props)

            cloud = make_cloud(tagged_cloud_props)

            expect(cloud).not_to receive(:current_vm_id)

            expect(creator).to receive(:create_via_ebs_direct).with(
              "/tmp/foo",
              encrypted: true,
              kms_key_arn: nil,
              tags: tags,
            ).and_return(stemcell)

            expect(cloud.create_stemcell("/tmp/foo", tagged_stemcell_properties)).to eq("ami-xxxxxxxx")
          end
        end
      end

      context "when encryption information is incomplete" do
        # `encrypted` false/absent means the stemcell is unencrypted even when a
        # kms_key_arn is present; the arn is still forwarded verbatim so the
        # creator can decide what to do with it.
        def expect_unencrypted_via_ebs_direct
          cloud = make_cloud(stemcell_cloud_props)

          expect(cloud).not_to receive(:current_vm_id)

          expect(creator).to receive(:create_via_ebs_direct).with(
            "/tmp/foo",
            encrypted: false,
            kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
            tags: {},
          ).and_return(stemcell)

          expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-xxxxxxxx")
        end

        context "when `encrypted` is false and kms_key_arn is provided" do
          let(:stemcell_properties) do
            {
              "root_device_name" => "/dev/sda1",
              "architecture" => "x86_64",
              "name" => "stemcell-name",
              "version" => "1.2.3",
              "virtualization_type" => "paravirtual",
              "encrypted" => false,
              "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
            }
          end

          it "should create an unencrypted stemcell" do
            expect_unencrypted_via_ebs_direct
          end
        end

        context "when `encrypted` is missing and kms_key_arn is provided" do
          let(:stemcell_properties) do
            {
              "root_device_name" => "/dev/sda1",
              "architecture" => "x86_64",
              "name" => "stemcell-name",
              "version" => "1.2.3",
              "virtualization_type" => "paravirtual",
              "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
            }
          end

          it "should create an unencrypted stemcell" do
            expect_unencrypted_via_ebs_direct
          end
        end
      end
    end
  end
end
