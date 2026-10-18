import Foundation

public enum CampusLighting:String,Codable,CaseIterable {
    case daylight,night,other
    public var title:String { switch self { case .daylight:return "白天";case .night:return "夜间";case .other:return "其他光照" } }
}

// A view guide is attached to a saved node, not to an old AR session origin.
// Its approximate pose is for choosing a helpful photo, not localization truth.
public struct CampusRecoveryGuide:Codable,Equatable {
    public var id:String,reference_node_id:String,name:String,created_utc:String
    public var lighting:CampusLighting
    public var camera_relative_to_node:[[Double]]
    public init(nodeID:String,name:String,lighting:CampusLighting,cameraRelativeToNode:[[Double]],id:String = UUID().uuidString) {
        self.id = id;reference_node_id = nodeID;self.name = name;self.lighting = lighting;camera_relative_to_node = cameraRelativeToNode;created_utc = ISO8601DateFormatter().string(from:Date())
    }
    public func validate(nodeIDs:Set<String>) throws {
        guard UUID(uuidString:id) != nil,nodeIDs.contains(reference_node_id),!name.isEmpty,name.count <= 120,
              RigidMatrix.valid(camera_relative_to_node),ISO8601DateFormatter().date(from:created_utc) != nil else { throw CampusError.corrupt }
    }
}
