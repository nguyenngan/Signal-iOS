//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
public extension TSGroupModel {
    // GroupsV2 TODO: Remove?
    var pendingMembers: Set<SignalServiceAddress> {
        return groupMembership.pendingMembers
    }

    // GroupsV2 TODO: Remove?
    var allPendingAndNonPendingMembers: Set<SignalServiceAddress> {
        return groupMembership.allUsers
    }
}

// MARK: -

// Like TSGroupModel, TSGroupModelV2 is intended to be immutable.
//
// NOTE: This class is tightly coupled to GroupManager.
//       If you modify this class - especially if you
//       add any new properties - make sure to update
//       GroupManager.buildGroupModel().
@objc
public class TSGroupModelV2: TSGroupModel {

    // These properties TSGroupModel, TSGroupModelV2 is intended to be immutable.
    @objc
    var membership: GroupMembership = GroupMembership.empty
    @objc
    var access: GroupAccess = GroupAccess.defaultForV2
    @objc
    var secretParamsData: Data = Data()
    @objc
    var revision: UInt32 = 0

    @objc
    public required init(groupId: Data,
                         name: String?,
                         avatarData: Data?,
                         groupMembership: GroupMembership,
                         groupAccess: GroupAccess,
                         revision: UInt32,
                         secretParamsData: Data) {
        assert(secretParamsData.count > 0)

        self.membership = groupMembership
        self.secretParamsData = secretParamsData
        self.access = groupAccess
        self.revision = revision

        super.init(groupId: groupId,
                   name: name,
                   avatarData: avatarData,
                   members: Array(groupMembership.nonPendingMembers))
    }

    // MARK: - MTLModel

    @objc
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    @objc
    public required init(dictionary dictionaryValue: [String: Any]!) throws {
        try super.init(dictionary: dictionaryValue)
    }

    // MARK: -

    @objc
    public override var groupsVersion: GroupsVersion {
        return .V2
    }

    @objc
    public override var groupMembership: GroupMembership {
        return membership
    }

    @objc
    public override var groupAccess: GroupAccess {
        return access
    }

    @objc
    public override var groupMembers: [SignalServiceAddress] {
        return Array(groupMembership.nonPendingMembers)
    }

    @objc
    public override var groupV2Revision: UInt32 {
        return revision
    }

    @objc
    public override var groupSecretParamsData: Data? {
        return secretParamsData
    }

    @objc
    public override func isEqual(to model: TSGroupModel) -> Bool {
        guard super.isEqual(to: model) else {
            return false
        }
        guard let other = model as? TSGroupModelV2 else {
            return false
        }
        guard other.membership == membership else {
            return false
        }
        guard other.access == access else {
            return false
        }
        guard other.secretParamsData == secretParamsData else {
            return false
        }
        guard other.revision == revision else {
            return false
        }
        return true
    }

    @objc
    public override var debugDescription: String {
        var result = "["
        result += "groupId: \(groupId.hexadecimalString),\n"
        result += "groupsVersion: \(groupsVersion),\n"
        result += "groupName: \(String(describing: groupName)),\n"
        result += "groupAvatarData: \(String(describing: groupAvatarData?.hexadecimalString)),\n"
        result += "membership: \(groupMembership.debugDescription),\n"
        result += "groupAccess: \(groupAccess.debugDescription),\n"
        result += "groupSecretParamsData: \(secretParamsData.hexadecimalString),\n"
        result += "revision: \(revision),\n"
        result += "]"
        return result
    }
}
