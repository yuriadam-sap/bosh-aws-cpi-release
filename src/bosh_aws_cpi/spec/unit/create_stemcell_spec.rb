require "spec_helper"

describe Bosh::AwsCloud::CloudV1 do
  before { @tmp_dir = Dir.mktmpdir }
  after { FileUtils.rm_rf(@tmp_dir) }

  describe "create_stemcell" do
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
      # The heavy-stemcell EBS-direct delegation (encryption, kms_key_arn, and
      # tag forwarding, and never touching current_vm_id / volume attach) is
      # covered in create_stemcell_ebs_direct_spec.rb. This context keeps only
      # what is specific to CloudV1#create_stemcell here.
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

      it "routes to the EBS-direct creator and returns the AMI id" do
        cloud = mock_cloud do |ec2|
          expect(Bosh::AwsCloud::StemcellCreator).to receive(:new)
              .with(ec2, stemcell_cloud_props)
              .and_return(creator)
        end

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
    end
  end
end
