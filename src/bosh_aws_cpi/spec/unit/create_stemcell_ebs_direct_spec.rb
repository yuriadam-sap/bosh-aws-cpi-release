require "spec_helper"

# The EBS-direct heavy-stemcell path must be creatable off-EC2 (e.g. inside a
# create-env container). These specs assert that when the `ebs_direct` config
# is set, create_stemcell delegates to StemcellCreator#create_via_ebs_direct
# and NEVER touches the EC2 metadata endpoint (current_vm_id) or attaches an
# EBS volume -- the two things that make the classic path fail off-EC2.
#
# The opt-in is landscape-specific, so its home is the CPI's global config
# (`cloud_provider.properties.aws.stemcell.ebs_direct`), which reaches the CPI
# as `config.aws.stemcell['ebs_direct']`. mock_cloud builds a *real*
# Config/AwsConfig/PropsFactory from the options hash, so ebs_direct is injected
# via aws.stemcell in the CPI options (NOT via test doubles). Only
# StemcellCreator -- the external AWS boundary -- is stubbed.
describe Bosh::AwsCloud::CloudV1 do
  before { @tmp_dir = Dir.mktmpdir }
  after { FileUtils.rm_rf(@tmp_dir) }

  describe "EBS-direct based flow" do
    let(:creator) { instance_double(Bosh::AwsCloud::StemcellCreator) }
    let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
    let(:az_selector) do
      instance_double(Bosh::AwsCloud::AvailabilityZoneSelector, select_availability_zone: "us-east-1a")
    end
    let(:stemcell) { instance_double(Bosh::AwsCloud::Stemcell, :id => "ami-ebs") }

    # Plain heavy-stemcell props with NO per-stemcell ebs_direct; the opt-in
    # comes from the global aws.stemcell config injected via mock_cloud.
    let(:stemcell_properties) do
      {
        "root_device_name" => "/dev/xvda",
        "architecture" => "x86_64",
        "name" => "stemcell-name",
        "version" => "1.2.3",
        "virtualization_type" => "hvm",
      }
    end

    def cloud_with_global_ebs_direct(ebs_direct, aws_overrides = {})
      options = mock_cloud_properties_merge(
        "aws" => { "stemcell" => { "ebs_direct" => ebs_direct } }.merge(aws_overrides),
      )
      mock_cloud(options) do
        allow(Bosh::AwsCloud::StemcellCreator).to receive(:new).and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
      end
    end

    it "creates a stemcell via EBS direct (opt-in from global aws.stemcell config) without touching EC2 metadata or EBS" do
      cloud = cloud_with_global_ebs_direct(true)

      expect(cloud).not_to receive(:current_vm_id)
      expect(volume_manager).not_to receive(:create_ebs_volume)
      expect(volume_manager).not_to receive(:attach_ebs_volume)

      expect(creator).to receive(:create_via_ebs_direct).with(
        "/tmp/foo",
        encrypted: false,
        kms_key_arn: nil,
        tags: {},
      ).and_return(stemcell)

      expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-ebs")
    end

    it "forwards the documented encrypted/kms_key_arn options" do
      cloud = cloud_with_global_ebs_direct(
        "encrypted" => true,
        "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
      )

      expect(creator).to receive(:create_via_ebs_direct).with(
        "/tmp/foo",
        encrypted: true,
        kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
        tags: {},
      ).and_return(stemcell)

      expect(cloud.create_stemcell("/tmp/foo", stemcell_properties)).to eq("ami-ebs")
    end

    it "falls back to the classic EBS-attach path when ebs_direct is not configured" do
      cloud = mock_cloud do
        allow(Bosh::AwsCloud::StemcellCreator).to receive(:new).and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
      end

      expect(creator).not_to receive(:create_via_ebs_direct)
      # classic path begins with current_vm_id; stub it so the test does not
      # reach the real metadata endpoint, and assert it IS consulted.
      expect(cloud).to receive(:current_vm_id).and_raise(
        Bosh::Clouds::CloudError.new("Timed out reading instance metadata, please make sure CPI is running on EC2 instance")
      )

      expect {
        cloud.create_stemcell("/tmp/foo", stemcell_properties)
      }.to raise_error(/Timed out reading instance metadata/)
    end
  end
end
