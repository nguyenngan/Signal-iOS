//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

#import "OWSIncomingSentMessageTranscript.h"
#import "OWSContact.h"
#import "OWSMessageManager.h"
#import "TSContactThread.h"
#import "TSGroupModel.h"
#import "TSGroupThread.h"
#import "TSOutgoingMessage.h"
#import "TSQuotedMessage.h"
#import "TSThread.h"
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSIncomingSentMessageTranscript ()

@property (nonatomic, readonly) SSKProtoDataMessage *dataMessage;

@end

#pragma mark -

@implementation OWSIncomingSentMessageTranscript

#pragma mark - Dependencies

+ (TSAccountManager *)tsAccountManager
{
    OWSAssertDebug(SSKEnvironment.shared.tsAccountManager);

    return SSKEnvironment.shared.tsAccountManager;
}

- (id<GroupsV2>)groupsV2
{
    return SSKEnvironment.shared.groupsV2;
}

#pragma mark -

- (nullable instancetype)initWithProto:(SSKProtoSyncMessageSent *)sentProto transaction:(SDSAnyWriteTransaction *)transaction
{
    self = [super init];
    if (!self) {
        return self;
    }

    if (sentProto.message == nil) {
        OWSFailDebug(@"Missing message.");
        return nil;
    }
    _dataMessage = sentProto.message;

    if (sentProto.timestamp < 1) {
        OWSFailDebug(@"Sent missing timestamp.");
        return nil;
    }
    _timestamp = sentProto.timestamp;
    _expirationStartedAt = sentProto.expirationStartTimestamp;
    _expirationDuration = _dataMessage.expireTimer;
    _body = _dataMessage.body;
    _dataMessageTimestamp = _dataMessage.timestamp;

    SSKProtoGroupContext *_Nullable groupContextV1 = _dataMessage.group;
    SSKProtoGroupContextV2 *_Nullable groupContextV2 = _dataMessage.groupV2;
    if (groupContextV1 != nil) {
        if (groupContextV2 != nil) {
            OWSFailDebug(@"Transcript has both v1 and v2 group contexts.");
            return nil;
        }

        _groupId = groupContextV1.id;
        if (_groupId.length < 1) {
            OWSFailDebug(@"Missing groupId.");
            return nil;
        }
        if (![GroupManager isValidGroupId:_groupId groupsVersion:GroupsVersionV1]) {
            OWSFailDebug(@"Invalid groupId.");
            return nil;
        }
        _isGroupUpdate = (groupContextV1.hasType && groupContextV1.unwrappedType == SSKProtoGroupContextTypeUpdate);
    } else if (groupContextV2 != nil) {
        NSData *_Nullable masterKey = groupContextV2.masterKey;
        if (masterKey.length < 1) {
            OWSFailDebug(@"Missing masterKey.");
            return nil;
        }
        NSError *_Nullable error;
        GroupV2ContextInfo *_Nullable contextInfo = [self.groupsV2 groupV2ContextInfoForMasterKeyData:masterKey
                                                                                                error:&error];
        if (error != nil || contextInfo == nil) {
            OWSFailDebug(@"Couldn't parse contextInfo: %@.", error);
            return nil;
        }
        _groupId = contextInfo.groupId;
        if (_groupId.length < 1) {
            OWSFailDebug(@"Missing groupId.");
            return nil;
        }
        if (![GroupManager isValidGroupId:_groupId groupsVersion:GroupsVersionV2]) {
            OWSFailDebug(@"Invalid groupId.");
            return nil;
        }
    } else {
        if (sentProto.destinationAddress == nil) {
            OWSFailDebug(@"Missing destinationAddress.");
            return nil;
        }
        _recipientAddress = sentProto.destinationAddress;
    }

    if (_dataMessage.hasFlags) {
        uint32_t flags = _dataMessage.flags;
        _isExpirationTimerUpdate = (flags & SSKProtoDataMessageFlagsExpirationTimerUpdate) != 0;
        _isEndSessionMessage = (flags & SSKProtoDataMessageFlagsEndSession) != 0;
    }
    _isRecipientUpdate = sentProto.hasIsRecipientUpdate && sentProto.isRecipientUpdate;
    _isViewOnceMessage = _dataMessage.hasIsViewOnce && _dataMessage.isViewOnce;

    if (_dataMessage.hasRequiredProtocolVersion) {
        _requiredProtocolVersion = @(_dataMessage.requiredProtocolVersion);
    }

    if (self.isRecipientUpdate) {
        // Fetch, don't create.  We don't want recipient updates to resurrect messages or threads.
        if (_groupId != nil) {
            _thread = [TSGroupThread fetchWithGroupId:_groupId transaction:transaction];
        } else {
            OWSFailDebug(@"We should never receive a 'recipient update' for messages in contact threads.");
            return nil;
        }
        // Skip the other processing for recipient updates.
    } else {
        if (_groupId != nil) {
            TSGroupThread *_Nullable groupThread = [TSGroupThread fetchWithGroupId:_groupId transaction:transaction];
            _thread = groupThread;

            if (groupContextV1 != nil) {
                if (_thread == nil) {
                    SignalServiceAddress *_Nullable localAddress
                        = OWSIncomingSentMessageTranscript.tsAccountManager.localAddress;
                    if (localAddress == nil) {
                        OWSFailDebug(@"Missing localAddress.");
                        return nil;
                    }
                    NSArray<SignalServiceAddress *> *members = @[ localAddress ];
                    NSError *_Nullable groupError;
                    _thread = [GroupManager upsertExistingGroupV1WithGroupId:_groupId
                                                                        name:groupContextV1.name
                                                                  avatarData:nil
                                                                     members:members
                                                    groupUpdateSourceAddress:localAddress
                                                           infoMessagePolicy:InfoMessagePolicyAlways
                                                                 transaction:transaction
                                                                       error:&groupError]
                                  .groupThread;
                    if (groupError != nil || _thread == nil) {
                        OWSFailDebug(@"Could not create group: %@", groupError);
                        return nil;
                    }
                }
                if (!_thread.isGroupV1Thread) {
                    OWSFailDebug(@"Invalid thread for v1 group.");
                    return nil;
                }
            } else if (groupContextV2 != nil) {
                if (groupThread == nil) {
                    // GroupsV2MessageProcessor should have already created the v2 group
                    // by now.
                    OWSFailDebug(@"Missing thread for v2 group.");
                    return nil;
                } else if (!_thread.isGroupV2Thread) {
                    OWSFailDebug(@"Invalid thread for v2 group.");
                    return nil;
                }
                if (!groupContextV2.hasRevision) {
                    OWSFailDebug(@"Missing revision.");
                    return nil;
                }
                uint32_t revision = groupContextV2.revision;
                if (revision > groupThread.groupModel.groupV2Revision) {
                    OWSFailDebug(@"Unexpected revision.");
                    return nil;
                }
            } else {
                OWSFailDebug(@"Missing group context.");
                return nil;
            }
        } else {
            _thread = [TSContactThread getOrCreateThreadWithContactAddress:_recipientAddress transaction:transaction];
        }

        _quotedMessage =
            [TSQuotedMessage quotedMessageForDataMessage:_dataMessage thread:_thread transaction:transaction];
        _contact = [OWSContacts contactForDataMessage:_dataMessage transaction:transaction];

        NSError *linkPreviewError;
        _linkPreview = [OWSLinkPreview buildValidatedLinkPreviewWithDataMessage:_dataMessage
                                                                           body:_body
                                                                    transaction:transaction
                                                                          error:&linkPreviewError];
        if (linkPreviewError && ![OWSLinkPreview isNoPreviewError:linkPreviewError]) {
            OWSLogError(@"linkPreviewError: %@", linkPreviewError);
        }

        NSError *stickerError;
        _messageSticker = [MessageSticker buildValidatedMessageStickerWithDataMessage:_dataMessage
                                                                          transaction:transaction
                                                                                error:&stickerError];
        if (stickerError && ![MessageSticker isNoStickerError:stickerError]) {
            OWSFailDebug(@"stickerError: %@", stickerError);
        }
    }

    if (sentProto.unidentifiedStatus.count > 0) {
        NSMutableArray<SignalServiceAddress *> *nonUdRecipientAddresses = [NSMutableArray new];
        NSMutableArray<SignalServiceAddress *> *udRecipientAddresses = [NSMutableArray new];
        for (SSKProtoSyncMessageSentUnidentifiedDeliveryStatus *statusProto in sentProto.unidentifiedStatus) {
            if (!statusProto.hasValidDestination) {
                OWSFailDebug(@"Delivery status proto is missing destination.");
                continue;
            }
            if (!statusProto.hasUnidentified) {
                OWSFailDebug(@"Delivery status proto is missing value.");
                continue;
            }
            SignalServiceAddress *recipientAddress = statusProto.destinationAddress;
            if (statusProto.unidentified) {
                [udRecipientAddresses addObject:recipientAddress];
            } else {
                [nonUdRecipientAddresses addObject:recipientAddress];
            }
        }
        _nonUdRecipientAddresses = [nonUdRecipientAddresses copy];
        _udRecipientAddresses = [udRecipientAddresses copy];
    }

    return self;
}

- (NSArray<SSKProtoAttachmentPointer *> *)attachmentPointerProtos
{
    if (self.isGroupUpdate && self.dataMessage.group.avatar) {
        return @[ self.dataMessage.group.avatar ];
    } else {
        return self.dataMessage.attachments;
    }
}

@end

NS_ASSUME_NONNULL_END
