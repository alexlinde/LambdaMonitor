import Foundation

public struct LambdaAPIResponse: Codable, Sendable {
    public let data: [String: OfferedInstanceType]

    public init(data: [String: OfferedInstanceType]) {
        self.data = data
    }
}

public struct OfferedInstanceType: Codable, Identifiable, Sendable {
    public let instanceType: InstanceTypeInfo
    public let regionsWithCapacityAvailable: [Region]

    public var id: String { instanceType.name }
    public var isAvailable: Bool { !regionsWithCapacityAvailable.isEmpty }

    public init(instanceType: InstanceTypeInfo, regionsWithCapacityAvailable: [Region]) {
        self.instanceType = instanceType
        self.regionsWithCapacityAvailable = regionsWithCapacityAvailable
    }

    enum CodingKeys: String, CodingKey {
        case instanceType = "instance_type"
        case regionsWithCapacityAvailable = "regions_with_capacity_available"
    }
}

public struct InstanceTypeInfo: Codable, Sendable {
    public let name: String
    public let description: String
    public let priceCentsPerHour: Int
    public let specs: InstanceSpecs

    public var pricePerHour: Double {
        Double(priceCentsPerHour) / 100.0
    }

    public var formattedPrice: String {
        String(format: "$%.2f/hr", pricePerHour)
    }

    public init(name: String, description: String, priceCentsPerHour: Int, specs: InstanceSpecs) {
        self.name = name
        self.description = description
        self.priceCentsPerHour = priceCentsPerHour
        self.specs = specs
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case priceCentsPerHour = "price_cents_per_hour"
        case specs
    }
}

public struct InstanceSpecs: Codable, Sendable {
    public let vcpus: Int
    public let memoryGib: Int
    public let storageGib: Int

    public init(vcpus: Int, memoryGib: Int, storageGib: Int) {
        self.vcpus = vcpus
        self.memoryGib = memoryGib
        self.storageGib = storageGib
    }

    enum CodingKeys: String, CodingKey {
        case vcpus
        case memoryGib = "memory_gib"
        case storageGib = "storage_gib"
    }
}

public struct Region: Codable, Identifiable, Sendable {
    public let name: String
    public let description: String

    public var id: String { name }

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

// MARK: - SSH Keys API

public struct SSHKeysResponse: Codable, Sendable {
    public let data: [SSHKey]

    public init(data: [SSHKey]) {
        self.data = data
    }
}

public struct SSHKey: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let publicKey: String

    public init(id: String, name: String, publicKey: String) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case publicKey = "public_key"
    }
}

// MARK: - Launch Instance API

public struct LaunchInstanceRequest: Codable, Sendable {
    public let regionName: String
    public let instanceTypeName: String
    public let sshKeyNames: [String]
    public let quantity: Int

    public init(regionName: String, instanceTypeName: String, sshKeyNames: [String], quantity: Int) {
        self.regionName = regionName
        self.instanceTypeName = instanceTypeName
        self.sshKeyNames = sshKeyNames
        self.quantity = quantity
    }

    enum CodingKeys: String, CodingKey {
        case regionName = "region_name"
        case instanceTypeName = "instance_type_name"
        case sshKeyNames = "ssh_key_names"
        case quantity
    }
}

public struct LaunchInstanceResponse: Codable, Sendable {
    public let data: LaunchInstanceData

    public init(data: LaunchInstanceData) {
        self.data = data
    }
}

public struct LaunchInstanceData: Codable, Sendable {
    public let instanceIds: [String]

    public init(instanceIds: [String]) {
        self.instanceIds = instanceIds
    }

    enum CodingKeys: String, CodingKey {
        case instanceIds = "instance_ids"
    }
}

public struct LambdaErrorResponse: Codable, Sendable {
    public let error: LambdaErrorDetail

    public init(error: LambdaErrorDetail) {
        self.error = error
    }
}

public struct LambdaErrorDetail: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct TerminateInstanceRequest: Codable, Sendable {
    public let instanceIds: [String]

    public init(instanceIds: [String]) {
        self.instanceIds = instanceIds
    }

    enum CodingKeys: String, CodingKey {
        case instanceIds = "instance_ids"
    }
}

// MARK: - Running Instances API

public struct RunningInstancesResponse: Codable, Sendable {
    public let data: [RunningInstance]

    public init(data: [RunningInstance]) {
        self.data = data
    }
}

public struct RunningInstance: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let status: String
    public let region: Region
    public let instanceType: InstanceTypeInfo
    public let hostname: String?
    public let ip: String?
    public let sshKeyNames: [String]
    public let fileSystemNames: [String]
    public let jupyterToken: String?
    public let jupyterUrl: String?

    public init(
        id: String,
        name: String? = nil,
        status: String,
        region: Region,
        instanceType: InstanceTypeInfo,
        hostname: String? = nil,
        ip: String? = nil,
        sshKeyNames: [String] = [],
        fileSystemNames: [String] = [],
        jupyterToken: String? = nil,
        jupyterUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.region = region
        self.instanceType = instanceType
        self.hostname = hostname
        self.ip = ip
        self.sshKeyNames = sshKeyNames
        self.fileSystemNames = fileSystemNames
        self.jupyterToken = jupyterToken
        self.jupyterUrl = jupyterUrl
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, region, hostname, ip
        case instanceType = "instance_type"
        case sshKeyNames = "ssh_key_names"
        case fileSystemNames = "file_system_names"
        case jupyterToken = "jupyter_token"
        case jupyterUrl = "jupyter_url"
    }
}
