import Foundation

public enum MockData {

    // MARK: - Specs

    public static let h100Specs = InstanceSpecs(vcpus: 26, memoryGib: 200, storageGib: 512)
    public static let a100Specs = InstanceSpecs(vcpus: 30, memoryGib: 200, storageGib: 512)
    public static let a6000Specs = InstanceSpecs(vcpus: 14, memoryGib: 46, storageGib: 512)
    public static let h200Specs = InstanceSpecs(vcpus: 26, memoryGib: 200, storageGib: 512)

    // MARK: - Regions

    public static let usWest1 = Region(name: "us-west-1", description: "California, USA")
    public static let usEast1 = Region(name: "us-east-1", description: "Virginia, USA")
    public static let euWest1 = Region(name: "eu-west-1", description: "London, UK")
    public static let asiaNortheast1 = Region(name: "asia-northeast-1", description: "Tokyo, Japan")

    // MARK: - Instance Types

    public static let h100x1Info = InstanceTypeInfo(
        name: "gpu_1x_h100_sxm5",
        description: "1x H100 SXM5 (80 GB)",
        priceCentsPerHour: 249,
        specs: h100Specs
    )

    public static let h100x8Info = InstanceTypeInfo(
        name: "gpu_8x_h100_sxm5",
        description: "8x H100 SXM5 (80 GB)",
        priceCentsPerHour: 2399,
        specs: h100Specs
    )

    public static let a100x1Info = InstanceTypeInfo(
        name: "gpu_1x_a100_sxm4",
        description: "1x A100 SXM4 (80 GB)",
        priceCentsPerHour: 149,
        specs: a100Specs
    )

    public static let a6000Info = InstanceTypeInfo(
        name: "gpu_1x_rtx6000",
        description: "1x RTX 6000 Ada (48 GB)",
        priceCentsPerHour: 89,
        specs: a6000Specs
    )

    public static let h200x1Info = InstanceTypeInfo(
        name: "gpu_1x_h200_sxm",
        description: "1x H200 SXM (141 GB)",
        priceCentsPerHour: 349,
        specs: h200Specs
    )

    // MARK: - Offered Instances

    public static let h100x1Available = OfferedInstanceType(
        instanceType: h100x1Info,
        regionsWithCapacityAvailable: [usWest1, usEast1]
    )

    public static let h100x8Available = OfferedInstanceType(
        instanceType: h100x8Info,
        regionsWithCapacityAvailable: [usWest1]
    )

    public static let a100x1Unavailable = OfferedInstanceType(
        instanceType: a100x1Info,
        regionsWithCapacityAvailable: []
    )

    public static let a6000Available = OfferedInstanceType(
        instanceType: a6000Info,
        regionsWithCapacityAvailable: [usWest1, euWest1, asiaNortheast1]
    )

    public static let h200x1Unavailable = OfferedInstanceType(
        instanceType: h200x1Info,
        regionsWithCapacityAvailable: []
    )

    // MARK: - SSH Keys

    public static let sshKey1 = SSHKey(
        id: "ssh-key-001", name: "my-laptop", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user@laptop"
    )

    public static let sshKey2 = SSHKey(
        id: "ssh-key-002", name: "work-desktop", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user@desktop"
    )

    // MARK: - Images

    public static let lambdaStackImage = LambdaImage(
        id: "43336648-096d-4cba-9aa2-f9bb7727639d",
        createdTime: Date(timeIntervalSince1970: 1_700_000_000),
        updatedTime: Date(timeIntervalSince1970: 1_700_000_000),
        name: "lambda-stack-22.04",
        description: "Lambda Stack",
        family: "lambda-stack",
        version: "22.04",
        architecture: .x86_64,
        region: usWest1
    )

    public static let ubuntuLtsImage = LambdaImage(
        id: "11111111-2222-3333-4444-555555555555",
        createdTime: Date(timeIntervalSince1970: 1_700_000_000),
        updatedTime: Date(timeIntervalSince1970: 1_700_000_000),
        name: "ubuntu-24.04.01",
        description: "Ubuntu LTS",
        family: "ubuntu-lts",
        version: "24.04.01",
        architecture: .x86_64,
        region: usEast1
    )

    public static let mixedImages: [LambdaImage] = [lambdaStackImage, ubuntuLtsImage]

    // MARK: - Running Instances

    public static let runningH100 = RunningInstance(
        id: "i-abc123def456",
        name: "training-run-7",
        status: "active",
        region: usWest1,
        instanceType: h100x1Info,
        hostname: "abc123.cloud.lambdalabs.com",
        ip: "203.0.113.42",
        sshKeyNames: ["my-laptop"],
        fileSystemNames: [],
        jupyterToken: "tok_abc123",
        jupyterUrl: "https://jupyter-abc123.cloud.lambdalabs.com"
    )

    public static let bootingA100 = RunningInstance(
        id: "i-boot000001",
        status: "booting",
        region: usEast1,
        instanceType: a100x1Info
    )

    public static let terminatingInstance = RunningInstance(
        id: "i-term000001",
        status: "terminating",
        region: euWest1,
        instanceType: a6000Info
    )

    // MARK: - Combined Sets

    public static let mixedInstances: [OfferedInstanceType] = [
        h100x1Available, h100x8Available, a100x1Unavailable, a6000Available, h200x1Unavailable
    ]

    public static let allUnavailable: [OfferedInstanceType] = [
        a100x1Unavailable, h200x1Unavailable
    ]

    public static let allAvailable: [OfferedInstanceType] = [
        h100x1Available, h100x8Available, a6000Available
    ]

    // MARK: - JSON Fixtures

    public static let instanceTypesJSON = """
    {
        "data": {
            "gpu_1x_h100_sxm5": {
                "instance_type": {
                    "name": "gpu_1x_h100_sxm5",
                    "description": "1x H100 SXM5 (80 GB)",
                    "price_cents_per_hour": 249,
                    "specs": { "vcpus": 26, "memory_gib": 200, "storage_gib": 512 }
                },
                "regions_with_capacity_available": [
                    { "name": "us-west-1", "description": "California, USA" }
                ]
            },
            "gpu_1x_a100_sxm4": {
                "instance_type": {
                    "name": "gpu_1x_a100_sxm4",
                    "description": "1x A100 SXM4 (80 GB)",
                    "price_cents_per_hour": 149,
                    "specs": { "vcpus": 30, "memory_gib": 200, "storage_gib": 512 }
                },
                "regions_with_capacity_available": []
            }
        }
    }
    """

    public static let runningInstancesJSON = """
    {
        "data": [
            {
                "id": "i-abc123def456",
                "name": "training-run-7",
                "status": "active",
                "region": { "name": "us-west-1", "description": "California, USA" },
                "instance_type": {
                    "name": "gpu_1x_h100_sxm5",
                    "description": "1x H100 SXM5 (80 GB)",
                    "price_cents_per_hour": 249,
                    "specs": { "vcpus": 26, "memory_gib": 200, "storage_gib": 512 }
                },
                "hostname": "abc123.cloud.lambdalabs.com",
                "ip": "203.0.113.42",
                "ssh_key_names": ["my-laptop"],
                "file_system_names": [],
                "jupyter_token": "tok_abc123",
                "jupyter_url": "https://jupyter-abc123.cloud.lambdalabs.com"
            }
        ]
    }
    """

    public static let runningInstanceMinimalJSON = """
    {
        "data": [
            {
                "id": "i-minimal001",
                "name": null,
                "status": "booting",
                "region": { "name": "us-east-1", "description": "Virginia, USA" },
                "instance_type": {
                    "name": "gpu_1x_a100_sxm4",
                    "description": "1x A100 SXM4 (80 GB)",
                    "price_cents_per_hour": 149,
                    "specs": { "vcpus": 30, "memory_gib": 200, "storage_gib": 512 }
                },
                "hostname": null,
                "ip": null,
                "ssh_key_names": [],
                "file_system_names": [],
                "jupyter_token": null,
                "jupyter_url": null
            }
        ]
    }
    """

    public static let sshKeysJSON = """
    {
        "data": [
            { "id": "ssh-key-001", "name": "my-laptop", "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user@laptop" },
            { "id": "ssh-key-002", "name": "work-desktop", "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user@desktop" }
        ]
    }
    """

    public static let imagesJSON = """
    {
        "data": [
            {
                "id": "43336648-096d-4cba-9aa2-f9bb7727639d",
                "created_time": "2023-11-14T22:13:20Z",
                "updated_time": "2023-11-14T22:13:20Z",
                "name": "lambda-stack-22.04",
                "description": "Lambda Stack",
                "family": "lambda-stack",
                "version": "22.04",
                "architecture": "x86_64",
                "region": { "name": "us-west-1", "description": "California, USA" }
            },
            {
                "id": "11111111-2222-3333-4444-555555555555",
                "created_time": "2023-11-14T22:13:20Z",
                "updated_time": "2023-11-14T22:13:20Z",
                "name": "ubuntu-24.04.01",
                "description": "Ubuntu LTS",
                "family": "ubuntu-lts",
                "version": "24.04.01",
                "architecture": "x86_64",
                "region": { "name": "us-east-1", "description": "Virginia, USA" }
            }
        ]
    }
    """

    public static let launchSuccessJSON = """
    { "data": { "instance_ids": ["i-new000001"] } }
    """

    public static let errorJSON = """
    { "error": { "code": "insufficient_capacity", "message": "Insufficient capacity for gpu_1x_h100_sxm5 in us-west-1" } }
    """

    public static let emptyInstanceTypesJSON = """
    { "data": {} }
    """

    public static let emptyRunningInstancesJSON = """
    { "data": [] }
    """
}

// MARK: - MockAPIClient Factories

extension MockAPIClient {
    public static func debug() -> MockAPIClient {
        let mock = MockAPIClient()
        mock.instanceTypesResult = .success(MockData.mixedInstances)
        mock.runningInstancesResult = .success([MockData.runningH100])
        mock.sshKeysResult = .success([MockData.sshKey1, MockData.sshKey2])
        mock.imagesResult = .success(MockData.mixedImages)
        mock.launchResult = .success(["i-debug-launched-001"])
        return mock
    }

    /// Deterministic mock for UI tests. Unlike `autoLaunchDemo`, every fetch
    /// returns the same instance types, so tests don't race fetch counters.
    /// A multi-region available type drives the launch sheet, an active running
    /// instance drives terminate flows, and `onLaunchInstance` appends new
    /// running instances so end-to-end launch can be observed in the UI.
    public static func uiTest() -> MockAPIClient {
        let mock = MockAPIClient()
        mock.delay = .milliseconds(800)
        // Launch/terminate run longer than a plain fetch so the progress
        // spinner in the launch/terminate Window stays on screen long enough
        // for XCUITest to reliably observe it (its first snapshot lands ~1.5s
        // after the confirming click).
        mock.operationDelay = .milliseconds(2500)
        mock.instanceTypesResult = .success([
            MockData.h100x1Available,
            MockData.a6000Available,
            MockData.a100x1Unavailable,
        ])
        mock.runningInstancesResult = .success([MockData.runningH100])
        mock.sshKeysResult = .success([MockData.sshKey1, MockData.sshKey2])
        mock.imagesResult = .success(MockData.mixedImages)
        mock.launchResult = .success(["i-uitest-launched-001"])

        let knownInfos: [String: InstanceTypeInfo] = [
            MockData.h100x1Info.name: MockData.h100x1Info,
            MockData.h100x8Info.name: MockData.h100x8Info,
            MockData.a100x1Info.name: MockData.a100x1Info,
            MockData.a6000Info.name: MockData.a6000Info,
            MockData.h200x1Info.name: MockData.h200x1Info,
        ]
        let knownRegions: [String: Region] = [
            MockData.usWest1.name: MockData.usWest1,
            MockData.usEast1.name: MockData.usEast1,
            MockData.euWest1.name: MockData.euWest1,
            MockData.asiaNortheast1.name: MockData.asiaNortheast1,
        ]

        var launchSequence = 0
        mock.onLaunchInstance = { [weak mock] typeName, regionName in
            guard let mock,
                  let info = knownInfos[typeName],
                  let region = knownRegions[regionName] else { return }

            launchSequence += 1
            // Encode the SSH key + image family that were actually sent to the
            // API into the synthesized instance's identifier so XCUITest can
            // assert the launch dialog's selection flowed through (the running
            // row's identifier is `running-row-<id>`).
            let launchedKey = mock.lastLaunchedSSHKeyNames?.first ?? "nokey"
            let launchedImage = mock.lastLaunchedImageFamily ?? "default"
            let new = RunningInstance(
                id: "i-uitest-\(launchedKey)-\(launchedImage)-\(launchSequence)",
                name: nil,
                status: "active",
                region: region,
                instanceType: info,
                hostname: "uitest-\(typeName).cloud.lambdalabs.com",
                ip: "10.0.0.\(launchSequence % 254 + 1)",
                sshKeyNames: mock.lastLaunchedSSHKeyNames ?? [],
                fileSystemNames: [],
                jupyterToken: nil,
                jupyterUrl: nil
            )
            if case .success(let existing) = mock.runningInstancesResult {
                mock.runningInstancesResult = .success(existing + [new])
            }
        }

        return mock
    }

    /// Creates a mock client that simulates an instance type becoming available
    /// after `fetchesBeforeAvailable` refresh cycles. The A100 starts unavailable
    /// and flips to available, triggering auto-launch if configured.
    /// Launches append a synthetic active `RunningInstance` so the demo reflects
    /// the new instance in the running list.
    public static func autoLaunchDemo(fetchesBeforeAvailable: Int = 2) -> MockAPIClient {
        let mock = MockAPIClient()
        mock.runningInstancesResult = .success([])
        mock.sshKeysResult = .success([MockData.sshKey1, MockData.sshKey2])
        mock.imagesResult = .success(MockData.mixedImages)
        mock.launchResult = .success(["i-auto-launched-001"])

        var fetchCount = 0
        mock.onFetchInstanceTypes = { _ in
            fetchCount += 1

            let a100: OfferedInstanceType
            if fetchCount > fetchesBeforeAvailable {
                a100 = OfferedInstanceType(
                    instanceType: MockData.a100x1Info,
                    regionsWithCapacityAvailable: [MockData.usEast1]
                )
            } else {
                a100 = MockData.a100x1Unavailable
            }

            return [
                MockData.a6000Available,
                a100,
                MockData.h200x1Unavailable,
            ]
        }

        let knownInfos: [String: InstanceTypeInfo] = [
            MockData.a100x1Info.name: MockData.a100x1Info,
            MockData.a6000Info.name: MockData.a6000Info,
            MockData.h200x1Info.name: MockData.h200x1Info,
            MockData.h100x1Info.name: MockData.h100x1Info,
            MockData.h100x8Info.name: MockData.h100x8Info,
        ]
        let knownRegions: [String: Region] = [
            MockData.usWest1.name: MockData.usWest1,
            MockData.usEast1.name: MockData.usEast1,
            MockData.euWest1.name: MockData.euWest1,
            MockData.asiaNortheast1.name: MockData.asiaNortheast1,
        ]

        var launchSequence = 0
        mock.onLaunchInstance = { [weak mock] typeName, regionName in
            guard let mock,
                  let info = knownInfos[typeName],
                  let region = knownRegions[regionName] else { return }

            launchSequence += 1
            let new = RunningInstance(
                id: String(format: "i-mock%08x", launchSequence),
                name: nil,
                status: "active",
                region: region,
                instanceType: info,
                hostname: "mock-\(typeName).cloud.lambdalabs.com",
                ip: "10.0.0.\(launchSequence % 254 + 1)",
                sshKeyNames: ["my-laptop"],
                fileSystemNames: [],
                jupyterToken: nil,
                jupyterUrl: nil
            )
            if case .success(let existing) = mock.runningInstancesResult {
                mock.runningInstancesResult = .success(existing + [new])
            }
        }

        return mock
    }
}

// MARK: - Preview Service Helpers

@MainActor
public enum PreviewService {
    public static func populated() -> LambdaAPIService {
        let mock = MockAPIClient.debug()
        let service = LambdaAPIService(client: mock, apiKeyOverride: "preview-key")
        service.instances = MockData.mixedInstances.sorted { lhs, rhs in
            if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
            return lhs.instanceType.description < rhs.instanceType.description
        }
        service.runningInstances = [MockData.runningH100]
        service.sshKeys = [MockData.sshKey1, MockData.sshKey2]
        service.images = MockData.mixedImages
        service.lastUpdated = Date()
        service.watchedTypes = ["gpu_1x_h100_sxm5"]
        return service
    }

    public static func loading() -> LambdaAPIService {
        let service = LambdaAPIService(client: MockAPIClient(), apiKeyOverride: "preview-key")
        service.isLoading = true
        return service
    }

    public static func error() -> LambdaAPIService {
        let service = LambdaAPIService(client: MockAPIClient(), apiKeyOverride: "preview-key")
        service.error = "Invalid API key"
        return service
    }

    public static func empty() -> LambdaAPIService {
        let service = LambdaAPIService(client: MockAPIClient(), apiKeyOverride: "preview-key")
        service.lastUpdated = Date()
        return service
    }

    public static func launching() -> LambdaAPIService {
        let service = populated()
        service.launchingTypeNames = ["gpu_1x_h100_sxm5"]
        service.activeLaunchProgress = LaunchOperationProgress(
            typeName: "gpu_1x_h100_sxm5",
            instanceDescription: "1x H100 (80 GB SXM5)",
            regionDescription: "US West",
            sshKeyName: "my-laptop",
            imageDescription: "Lambda Stack (latest)"
        )
        return service
    }
}
