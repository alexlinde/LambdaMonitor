import Foundation

struct LambdaAPIResponse: Codable {
    let data: [String: OfferedInstanceType]
}

struct OfferedInstanceType: Codable, Identifiable {
    let instanceType: InstanceTypeInfo
    let regionsWithCapacityAvailable: [Region]

    var id: String { instanceType.name }
    var isAvailable: Bool { !regionsWithCapacityAvailable.isEmpty }

    enum CodingKeys: String, CodingKey {
        case instanceType = "instance_type"
        case regionsWithCapacityAvailable = "regions_with_capacity_available"
    }
}

struct InstanceTypeInfo: Codable {
    let name: String
    let description: String
    let priceCentsPerHour: Int
    let specs: InstanceSpecs

    var pricePerHour: Double {
        Double(priceCentsPerHour) / 100.0
    }

    var formattedPrice: String {
        String(format: "$%.2f/hr", pricePerHour)
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case priceCentsPerHour = "price_cents_per_hour"
        case specs
    }
}

struct InstanceSpecs: Codable {
    let vcpus: Int
    let memoryGib: Int
    let storageGib: Int

    enum CodingKeys: String, CodingKey {
        case vcpus
        case memoryGib = "memory_gib"
        case storageGib = "storage_gib"
    }
}

struct Region: Codable, Identifiable {
    let name: String
    let description: String

    var id: String { name }
}

// MARK: - Launch Instance API

struct LaunchInstanceRequest: Codable {
    let regionName: String
    let instanceTypeName: String
    let sshKeyNames: [String]
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case regionName = "region_name"
        case instanceTypeName = "instance_type_name"
        case sshKeyNames = "ssh_key_names"
        case quantity
    }
}

struct LaunchInstanceResponse: Codable {
    let data: LaunchInstanceData
}

struct LaunchInstanceData: Codable {
    let instanceIds: [String]

    enum CodingKeys: String, CodingKey {
        case instanceIds = "instance_ids"
    }
}

struct LambdaErrorResponse: Codable {
    let error: LambdaErrorDetail
}

struct LambdaErrorDetail: Codable {
    let code: String
    let message: String
}

struct TerminateInstanceRequest: Codable {
    let instanceIds: [String]

    enum CodingKeys: String, CodingKey {
        case instanceIds = "instance_ids"
    }
}

// MARK: - Running Instances API

struct RunningInstancesResponse: Codable {
    let data: [RunningInstance]
}

struct RunningInstance: Codable, Identifiable {
    let id: String
    let name: String?
    let status: String
    let region: Region
    let instanceType: InstanceTypeInfo
    let hostname: String?
    let ip: String?
    let sshKeyNames: [String]
    let fileSystemNames: [String]
    let jupyterToken: String?
    let jupyterUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, region, hostname, ip
        case instanceType = "instance_type"
        case sshKeyNames = "ssh_key_names"
        case fileSystemNames = "file_system_names"
        case jupyterToken = "jupyter_token"
        case jupyterUrl = "jupyter_url"
    }
}
