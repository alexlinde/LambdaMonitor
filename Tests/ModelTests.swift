import Testing
import Foundation
@testable import LambdaMonitorCore

@Suite("Model Decoding")
struct ModelTests {

    // MARK: - Instance Types

    @Test("Decode mixed instance types with available and unavailable")
    func decodeInstanceTypes() throws {
        let data = Data(MockData.instanceTypesJSON.utf8)
        let response = try JSONDecoder().decode(LambdaAPIResponse.self, from: data)

        #expect(response.data.count == 2)

        let h100 = try #require(response.data["gpu_1x_h100_sxm5"])
        #expect(h100.instanceType.name == "gpu_1x_h100_sxm5")
        #expect(h100.instanceType.description == "1x H100 SXM5 (80 GB)")
        #expect(h100.instanceType.priceCentsPerHour == 249)
        #expect(h100.instanceType.specs.vcpus == 26)
        #expect(h100.instanceType.specs.memoryGib == 200)
        #expect(h100.instanceType.specs.storageGib == 512)
        #expect(h100.isAvailable)
        #expect(h100.regionsWithCapacityAvailable.count == 1)
        #expect(h100.regionsWithCapacityAvailable[0].name == "us-west-1")

        let a100 = try #require(response.data["gpu_1x_a100_sxm4"])
        #expect(!a100.isAvailable)
        #expect(a100.regionsWithCapacityAvailable.isEmpty)
    }

    @Test("Decode empty instance types response")
    func decodeEmptyInstanceTypes() throws {
        let data = Data(MockData.emptyInstanceTypesJSON.utf8)
        let response = try JSONDecoder().decode(LambdaAPIResponse.self, from: data)
        #expect(response.data.isEmpty)
    }

    @Test("InstanceTypeInfo computed properties")
    func instanceTypeComputedProperties() {
        let info = MockData.h100x1Info
        #expect(info.pricePerHour == 2.49)
        #expect(info.formattedPrice == "$2.49/hr")
    }

    @Test("OfferedInstanceType identity uses instance type name")
    func offeredInstanceTypeIdentity() {
        #expect(MockData.h100x1Available.id == "gpu_1x_h100_sxm5")
    }

    // MARK: - Running Instances

    @Test("Decode running instance with all fields")
    func decodeRunningInstanceFull() throws {
        let data = Data(MockData.runningInstancesJSON.utf8)
        let response = try JSONDecoder().decode(RunningInstancesResponse.self, from: data)

        #expect(response.data.count == 1)
        let instance = response.data[0]
        #expect(instance.id == "i-abc123def456")
        #expect(instance.name == "training-run-7")
        #expect(instance.status == "active")
        #expect(instance.region.name == "us-west-1")
        #expect(instance.instanceType.name == "gpu_1x_h100_sxm5")
        #expect(instance.hostname == "abc123.cloud.lambdalabs.com")
        #expect(instance.ip == "203.0.113.42")
        #expect(instance.sshKeyNames == ["my-laptop"])
        #expect(instance.fileSystemNames.isEmpty)
        #expect(instance.jupyterToken == "tok_abc123")
        #expect(instance.jupyterUrl == "https://jupyter-abc123.cloud.lambdalabs.com")
    }

    @Test("Decode running instance with null optional fields")
    func decodeRunningInstanceMinimal() throws {
        let data = Data(MockData.runningInstanceMinimalJSON.utf8)
        let response = try JSONDecoder().decode(RunningInstancesResponse.self, from: data)

        #expect(response.data.count == 1)
        let instance = response.data[0]
        #expect(instance.id == "i-minimal001")
        #expect(instance.name == nil)
        #expect(instance.status == "booting")
        #expect(instance.hostname == nil)
        #expect(instance.ip == nil)
        #expect(instance.sshKeyNames.isEmpty)
        #expect(instance.jupyterToken == nil)
        #expect(instance.jupyterUrl == nil)
    }

    @Test("Decode empty running instances")
    func decodeEmptyRunningInstances() throws {
        let data = Data(MockData.emptyRunningInstancesJSON.utf8)
        let response = try JSONDecoder().decode(RunningInstancesResponse.self, from: data)
        #expect(response.data.isEmpty)
    }

    // MARK: - SSH Keys

    @Test("Decode SSH keys")
    func decodeSSHKeys() throws {
        let data = Data(MockData.sshKeysJSON.utf8)
        let response = try JSONDecoder().decode(SSHKeysResponse.self, from: data)

        #expect(response.data.count == 2)
        #expect(response.data[0].id == "ssh-key-001")
        #expect(response.data[0].name == "my-laptop")
        #expect(response.data[0].publicKey.hasPrefix("ssh-ed25519"))
        #expect(response.data[1].name == "work-desktop")
    }

    // MARK: - Launch / Terminate

    @Test("Decode launch success response")
    func decodeLaunchSuccess() throws {
        let data = Data(MockData.launchSuccessJSON.utf8)
        let response = try JSONDecoder().decode(LaunchInstanceResponse.self, from: data)
        #expect(response.data.instanceIds == ["i-new000001"])
    }

    @Test("Decode API error response")
    func decodeErrorResponse() throws {
        let data = Data(MockData.errorJSON.utf8)
        let response = try JSONDecoder().decode(LambdaErrorResponse.self, from: data)
        #expect(response.error.code == "insufficient_capacity")
        #expect(response.error.message.contains("Insufficient capacity"))
    }

    @Test("Encode launch request preserves snake_case keys")
    func encodeLaunchRequest() throws {
        let request = LaunchInstanceRequest(
            regionName: "us-west-1",
            instanceTypeName: "gpu_1x_h100_sxm5",
            sshKeyNames: ["my-key"],
            quantity: 1
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["region_name"] as? String == "us-west-1")
        #expect(json["instance_type_name"] as? String == "gpu_1x_h100_sxm5")
        #expect(json["ssh_key_names"] as? [String] == ["my-key"])
        #expect(json["quantity"] as? Int == 1)
    }

    @Test("Encode terminate request preserves snake_case keys")
    func encodeTerminateRequest() throws {
        let request = TerminateInstanceRequest(instanceIds: ["i-abc123"])
        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["instance_ids"] as? [String] == ["i-abc123"])
    }

    // MARK: - Round-trip

    @Test("Model round-trip encode/decode preserves data")
    func roundTrip() throws {
        let original = MockData.h100x1Available
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OfferedInstanceType.self, from: data)
        #expect(decoded.instanceType.name == original.instanceType.name)
        #expect(decoded.instanceType.priceCentsPerHour == original.instanceType.priceCentsPerHour)
        #expect(decoded.regionsWithCapacityAvailable.count == original.regionsWithCapacityAvailable.count)
    }

    @Test("RunningInstance round-trip preserves optional fields")
    func runningInstanceRoundTrip() throws {
        let original = MockData.bootingA100
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RunningInstance.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.name == nil)
        #expect(decoded.hostname == nil)
        #expect(decoded.ip == nil)
        #expect(decoded.status == "booting")
    }
}
