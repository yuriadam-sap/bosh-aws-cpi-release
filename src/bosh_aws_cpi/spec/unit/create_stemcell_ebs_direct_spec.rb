require "spec_helper"

# Heavy stemcells always use the EBS-direct path (no opt-in config needed).
# These specs assert create_stemcell delegates to
# StemcellCreator#create_via_ebs_direct and NEVER touches the EC2 metadata
# endpoint (current_vm_id) or attaches an EBS volume -- the two things that
# make the classic path fail off-EC2.
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

    let(:stemcell_properties) do
      {
        "root_device_name" => "/dev/xvda",
        "architecture" => "x86_64",
        "name" => "stemcell-name",
        "version" => "1.2.3",
        "virtualization_type" => "hvm",
      }
    end

    def make_cloud
      mock_cloud do
        allow(Bosh::AwsCloud::StemcellCreator).to receive(:new).and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
      end
    end

    it "creates a stemcell via EBS direct without touching EC2 metadata or EBS" do
      cloud = make_cloud

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
      options = mock_cloud_properties_merge(
        "aws" => {
          "stemcell" => {
            "encrypted" => true,
            "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
          },
        },
      )
      cloud = mock_cloud(options) do
        allow(Bosh::AwsCloud::StemcellCreator).to receive(:new).and_return(creator)
        allow(Bosh::AwsCloud::VolumeManager).to receive(:new).and_return(volume_manager)
        allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
      end

      props_with_encryption = stemcell_properties.merge(
        "encrypted" => true,
        "kms_key_arn" => "arn:aws:kms:us-east-1:ID:key/GUID",
      )

      expect(creator).to receive(:create_via_ebs_direct).with(
        "/tmp/foo",
        encrypted: true,
        kms_key_arn: "arn:aws:kms:us-east-1:ID:key/GUID",
        tags: {},
      ).and_return(stemcell)

      expect(cloud.create_stemcell("/tmp/foo", props_with_encryption)).to eq("ami-ebs")
    end
  end
end
