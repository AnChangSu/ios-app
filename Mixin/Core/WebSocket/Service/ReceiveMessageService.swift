import Foundation
import Bugsnag
import UIKit

class ReceiveMessageService: MixinService {

    static let shared = ReceiveMessageService()

    private let processDispatchQueue = DispatchQueue(label: "one.mixin.messenger.queue.receive.messages")
    private let receiveDispatchQueue = DispatchQueue(label: "one.mixin.messenger.queue.receive")
    private let prekeyMiniNum = 500

    let messageDispatchQueue = DispatchQueue(label: "one.mixin.messenger.queue.messages")
    var refreshRefreshOneTimePreKeys = [String: TimeInterval]()

    override init() {
        processDispatchQueue.async {
            ReceiveMessageService.shared.checkSignalKey()
        }
    }

    func receiveMessage(blazeMessage: BlazeMessage, rawData: Data) {
        receiveDispatchQueue.async {
            guard let data = blazeMessage.toBlazeMessageData() else {
                return
            }

            if blazeMessage.action == BlazeMessageAction.acknowledgeMessageReceipt.rawValue {
                MessageDAO.shared.updateMessageStatus(messageId: data.messageId, status: data.status)
                CryptoUserDefault.shared.statusOffset = data.updatedAt.toUTCDate().nanosecond()
            } else if blazeMessage.action == BlazeMessageAction.createMessage.rawValue {
                if data.userId == AccountAPI.shared.accountUserId && data.category.isEmpty {
                    MessageDAO.shared.updateMessageStatus(messageId: data.messageId, status: data.status)
                } else {
                    var success = false
                    defer {
                        FileManager.default.writeLog(conversationId: data.conversationId, log: "[Receive][\(data.category)]...\(data.messageId)...\(data.createdAt)...insertOrReplace:\(success)")
                    }
                    guard BlazeMessageDAO.shared.insertOrReplace(messageId: data.messageId, data: blazeMessage.data, createdAt: data.createdAt) else {
                        UIApplication.trackError("ReceiveMessageService", action: "receiveMessage insert failed")
                        return
                    }
                    success = true
                    ReceiveMessageService.shared.processReceiveMessages()
                }
            }
        }
    }

    func processReceiveMessages() {
        guard !processing else {
            return
        }
        processing = true

        processDispatchQueue.async {
            defer {
                ReceiveMessageService.shared.processing = false
            }
            repeat {
                let blazeMessageDatas = BlazeMessageDAO.shared.getBlazeMessageData(limit: 50)
                guard blazeMessageDatas.count > 0 else {
                    return
                }

                for data in blazeMessageDatas {
                    guard AccountAPI.shared.didLogin else {
                        return
                    }
                    if MessageDAO.shared.isExist(messageId: data.messageId) || MessageHistoryDAO.shared.isExist(messageId: data.messageId) {
                        BlazeMessageDAO.shared.delete(data: data)
                        continue
                    }

                    ReceiveMessageService.shared.syncConversation(data: data)
                    ReceiveMessageService.shared.processSystemMessage(data: data)
                    ReceiveMessageService.shared.processPlainMessage(data: data)
                    ReceiveMessageService.shared.processSignalMessage(data: data)
                    ReceiveMessageService.shared.processAppButton(data: data)
                    BlazeMessageDAO.shared.delete(data: data)
                }
            } while true
        }
    }

    private func processAppButton(data: BlazeMessageData) {
        guard data.category == MessageCategory.APP_BUTTON_GROUP.rawValue || data.category == MessageCategory.APP_CARD.rawValue else {
            return
        }
        MessageDAO.shared.insertMessage(message: Message.createMessage(appMessage: data), messageSource: data.source)
        updateRemoteMessageStatus(messageId: data.messageId, status: .READ, createdAt: data.createdAt)
    }

    private func processSignalMessage(data: BlazeMessageData) {
        guard data.category.hasPrefix("SIGNAL_") else {
            return
        }
        let username = UserDAO.shared.getUser(userId: data.userId)?.fullName ?? data.userId

        if data.category == MessageCategory.SIGNAL_KEY.rawValue {
            updateRemoteMessageStatus(messageId: data.messageId, status: .READ, createdAt: data.createdAt)
            MessageHistoryDAO.shared.replaceMessageHistory(messageId: data.messageId)
        } else {
            updateRemoteMessageStatus(messageId: data.messageId, status: .DELIVERED, createdAt: data.createdAt)
        }

        let decoded = SignalProtocol.shared.decodeMessageData(encoded: data.data)
        do {
            try SignalProtocol.shared.decrypt(groupId: data.conversationId, senderId: data.userId, keyType: decoded.keyType, cipherText: decoded.cipher, category: data.category, callback: { (plain) in
                if data.category != MessageCategory.SIGNAL_KEY.rawValue {
                    let plainText = String(data: plain, encoding: .utf8)!
                    if let messageId = decoded.resendMessageId {
                        self.processRedecryptMessage(data: data, messageId: messageId, plainText: plainText)
                        self.updateRemoteMessageStatus(messageId: data.messageId, status: .READ, createdAt: data.createdAt)
                        MessageHistoryDAO.shared.replaceMessageHistory(messageId: data.messageId)
                    } else {
                        self.processDecryptSuccess(data: data, plainText: plainText)
                    }
                }
            })
            let status = SignalProtocol.shared.getRatchetSenderKeyStatus(groupId: data.conversationId, senderId: data.userId)
            FileManager.default.writeLog(conversationId: data.conversationId, log: "[ProcessSignalMessage][\(username)][\(data.category)]...decrypt success...messageId:\(data.messageId)...\(data.createdAt)...status:\(status)...source:\(data.source)...redecryptMessage:\(decoded.resendMessageId != nil)")
            if status == RatchetStatus.REQUESTING.rawValue {
                SignalProtocol.shared.deleteRatchetSenderKey(groupId: data.conversationId, senderId: data.userId)
                self.requestResendMessage(conversationId: data.conversationId, userId: data.userId)
            }
        } catch {
            trackDecryptFailed(data: data, dataHeader: decoded, error: error)
            FileManager.default.writeLog(conversationId: data.conversationId, log: "[ProcessSignalMessage][\(username)][\(data.category)][\(CiphertextMessage.MessageType.toString(rawValue: decoded.keyType))]...decrypt failed...\(error)...messageId:\(data.messageId)...\(data.createdAt)...source:\(data.source)...resendMessageId:\(decoded.resendMessageId ?? "")")
            guard decoded.resendMessageId == nil else {
                return
            }
            if (data.category == MessageCategory.SIGNAL_KEY.rawValue) {
                SignalProtocol.shared.deleteRatchetSenderKey(groupId: data.conversationId, senderId: data.userId)
                refreshKeys(conversationId: data.conversationId, username: username)
            } else {
                insertFailedMessage(data: data)
                refreshKeys(conversationId: data.conversationId, username: username)
                let status = SignalProtocol.shared.getRatchetSenderKeyStatus(groupId: data.conversationId, senderId: data.userId)
                if status != RatchetStatus.REQUESTING.rawValue {
                    requestResendKey(conversationId: data.conversationId, userId: data.userId, messageId: data.messageId)
                    SignalProtocol.shared.setRatchetSenderKeyStatus(groupId: data.conversationId, senderId: data.userId, status: RatchetStatus.REQUESTING.rawValue)
                }
            }
        }
    }

    private func refreshKeys(conversationId: String, username: String) {
        let now = Date().timeIntervalSince1970
        guard now - (refreshRefreshOneTimePreKeys[conversationId] ?? 0) > 60 else {
            return
        }
        refreshRefreshOneTimePreKeys[conversationId] = now
        FileManager.default.writeLog(conversationId: conversationId, log: "[ProcessSignalMessage][\(username)]...refreshKeys...")
        refreshKeys()
    }

    private func refreshKeys() {
        let countBlazeMessage = BlazeMessage(action: BlazeMessageAction.countSignalKeys.rawValue)
        guard let count = deliverKeys(blazeMessage: countBlazeMessage)?.toSignalKeyCount(), count.preKeyCount <= prekeyMiniNum else {
            return
        }
        guard let request = (try? PreKeyUtil.generateKeys()) else {
            return
        }
        let blazeMessage = BlazeMessage(params: BlazeMessageParam(syncSignalKeys: request), action: BlazeMessageAction.syncSignalKeys.rawValue)
        deliverNoThrow(blazeMessage: blazeMessage)
    }

    private func checkSignalKey() {
        switch SignalKeyAPI.shared.getSignalKeyCount() {
        case let .success(response):
            guard response.preKeyCount < prekeyMiniNum else {
                return
            }
            refreshKeys()
        case let .failure(error):
            Bugsnag.notifyError(error)
        }
    }

    private func trackDecryptFailed(data: BlazeMessageData, dataHeader: SignalProtocol.ComposeMessageData, error: Error) {
        guard data.category == MessageCategory.SIGNAL_KEY.rawValue, let signalError = error as? SignalError, signalError != .noSession else {
            return
        }
        let errorInfo = "\(error)"
        var userInfo = UIApplication.getTrackUserInfo()
        userInfo["messageId"] = data.messageId
        userInfo["userId"] = data.userId
        userInfo["conversationId"] = data.conversationId
        userInfo["category"] = data.category
        userInfo["createdAt"] = data.createdAt
        userInfo["source"] = data.source
        userInfo["error"] = errorInfo
        userInfo["keyType"] = CiphertextMessage.MessageType.toString(rawValue: dataHeader.keyType)
        userInfo["resendMessageId"] = dataHeader.resendMessageId ?? ""
        UIApplication.trackError("ReceiveMessageService", action: "signal key decrypt failed \(errorInfo)", userInfo: userInfo)
    }
    
    private func processDecryptSuccess(data: BlazeMessageData, plainText: String) {
        if data.category.hasSuffix("_TEXT") {
            var content = plainText
            if data.category == MessageCategory.PLAIN_TEXT.rawValue {
                guard let decoded = plainText.base64Decoded() else {
                    return
                }
                content = decoded
            }
            MessageDAO.shared.insertMessage(message: Message.createMessage(textMessage: content, data: data), messageSource: data.source)
        } else if data.category.hasSuffix("_IMAGE") || data.category.hasSuffix("_DATA")  {
            guard let base64Data = Data(base64Encoded: plainText), let transferMediaData = (try? jsonDecoder.decode(TransferAttachmentData.self, from: base64Data)) else {
                return
            }
            MessageDAO.shared.insertMessage(message: Message.createMessage(mediaData: transferMediaData, data: data), messageSource: data.source)
        } else if data.category.hasSuffix("_STICKER") {
            guard let base64Data = Data(base64Encoded: plainText), let transferStickerData = (try? jsonDecoder.decode(TransferStickerData.self, from: base64Data)) else {
                return
            }

            if !StickerDAO.shared.isExist(albumId: transferStickerData.albumId, name: transferStickerData.name) {
                do {
                    try RefreshStickerJob.cacheStickers(albumId: transferStickerData.albumId)
                } catch {
                    ConcurrentJobQueue.shared.addJob(job: RefreshStickerJob(albumId: transferStickerData.albumId))
                }
            }
            MessageDAO.shared.insertMessage(message: Message.createMessage(stickerData: transferStickerData, data: data), messageSource: data.source)
        } else if data.category.hasSuffix("_CONTACT") {
            guard let base64Data = Data(base64Encoded: plainText), let transferData = (try? jsonDecoder.decode(TransferContactData.self, from: base64Data)) else {
                return
            }
            guard syncUser(userId: transferData.userId) else {
                var userInfo = UIApplication.getTrackUserInfo()
                userInfo["sharedUserId"] = transferData.userId
                UIApplication.trackError("ReceiveMessageService", action: "share contact failed", userInfo: userInfo)
                return
            }
            MessageDAO.shared.insertMessage(message: Message.createMessage(contactData: transferData, data: data), messageSource: data.source)
        }
    }

    private func insertFailedMessage(data: BlazeMessageData) {
        guard data.category == MessageCategory.SIGNAL_TEXT.rawValue || data.category == MessageCategory.SIGNAL_IMAGE.rawValue || data.category == MessageCategory.SIGNAL_DATA.rawValue || data.category == MessageCategory.SIGNAL_CONTACT.rawValue || data.category == MessageCategory.SIGNAL_STICKER.rawValue else {
            return
        }
        var failedMessage = Message.createMessage(messageId: data.messageId, category: data.category, conversationId: data.conversationId, createdAt: data.createdAt, userId: data.userId)
        failedMessage.status = MessageStatus.FAILED.rawValue
        failedMessage.content = data.data
        MessageDAO.shared.insertMessage(message: failedMessage, messageSource: data.source)
    }

    private func processRedecryptMessage(data: BlazeMessageData, messageId: String, plainText: String) {
        switch data.category {
        case MessageCategory.SIGNAL_TEXT.rawValue:
            MessageDAO.shared.updateMessageContentAndStatus(content: plainText, status: MessageStatus.DELIVERED.rawValue, messageId: messageId, conversationId: data.conversationId)
        case MessageCategory.SIGNAL_IMAGE.rawValue, MessageCategory.SIGNAL_DATA.rawValue:
            guard let base64Data = Data(base64Encoded: plainText), let transferMediaData = (try? jsonDecoder.decode(TransferAttachmentData.self, from: base64Data)) else {
                return
            }
            let mediaStatus: MediaStatus
            switch data.category {
            case MessageCategory.SIGNAL_DATA.rawValue:
                mediaStatus = MediaStatus.CANCELED
            default:
                mediaStatus = MediaStatus.PENDING
            }

            if (data.category == MessageCategory.SIGNAL_IMAGE.rawValue || data.category == MessageCategory.SIGNAL_DATA.rawValue) && transferMediaData.size == 0 {
            }
            MessageDAO.shared.updateMediaMessage(mediaData: transferMediaData, status: MessageStatus.DELIVERED.rawValue, messageId: messageId, conversationId: data.conversationId, mediaStatus: mediaStatus)
        case MessageCategory.SIGNAL_STICKER.rawValue:
            guard let base64Data = Data(base64Encoded: plainText), let transferStickerData = (try? jsonDecoder.decode(TransferStickerData.self, from: base64Data)) else {
                return
            }
            if !StickerDAO.shared.isExist(albumId: transferStickerData.albumId, name: transferStickerData.name) {
                do {
                    try RefreshStickerJob.cacheStickers(albumId: transferStickerData.albumId)
                } catch {
                    ConcurrentJobQueue.shared.addJob(job: RefreshStickerJob(albumId: transferStickerData.albumId))
                }
            }
            MessageDAO.shared.updateStickerMessage(stickerData: transferStickerData, status: MessageStatus.DELIVERED.rawValue, messageId: messageId, conversationId: data.conversationId)
        case MessageCategory.SIGNAL_CONTACT.rawValue:
            guard let base64Data = Data(base64Encoded: plainText), let transferData = (try? jsonDecoder.decode(TransferContactData.self, from: base64Data)) else {
                return
            }
            guard syncUser(userId: transferData.userId) else {
                var userInfo = UIApplication.getTrackUserInfo()
                userInfo["sharedUserId"] = transferData.userId
                UIApplication.trackError("ReceiveMessageService", action: "processRedecryptMessage share contact failed", userInfo: userInfo)
                return
            }
            MessageDAO.shared.updateContactMessage(transferData: transferData, status: MessageStatus.DELIVERED.rawValue, messageId: messageId, conversationId: data.conversationId)
        default:
            break
        }
    }

    private func syncConversation(data: BlazeMessageData) {
        if let status = ConversationDAO.shared.getConversationStatus(conversationId: data.conversationId) {
            if status == ConversationStatus.SUCCESS.rawValue || status == ConversationStatus.QUIT.rawValue {
                return
            } else if status == ConversationStatus.START.rawValue && ConversationDAO.shared.getConversationCategory(conversationId: data.conversationId) == ConversationCategory.GROUP.rawValue {
                // from NewGroupViewController
                return
            }
        } else {
            switch ConversationAPI.shared.getConversation(conversationId: data.conversationId) {
            case let .success(response):
                let userIds = response.participants.flatMap({ (participant) -> String in
                    return participant.userId
                }).filter({ (userId) -> Bool in
                    return userId != currentAccountId
                })

                var updatedUsers = true
                if userIds.count > 0 {
                    switch UserAPI.shared.showUsers(userIds: userIds) {
                    case let .success(users):
                        UserDAO.shared.updateUsers(users: users)
                    case .failure:
                        updatedUsers = false
                    }
                }
                if !ConversationDAO.shared.createConversation(conversation: response, targetStatus: .SUCCESS) || !updatedUsers {
                    ConcurrentJobQueue.shared.addJob(job: RefreshConversationJob(conversationId: data.conversationId))
                }
                return
            case .failure:
                ConversationDAO.shared.createPlaceConversation(conversationId: data.conversationId, ownerId: data.userId)
            }
        }
        ConcurrentJobQueue.shared.addJob(job: RefreshConversationJob(conversationId: data.conversationId))
    }

    @discardableResult
    private func checkUser(userId: String, tryAgain: Bool = false) -> ParticipantStatus {
        guard !userId.isEmpty else {
            return .ERROR
        }
        guard User.systemUser != userId, userId != currentAccountId, !UserDAO.shared.isExist(userId: userId) else {
            return .SUCCESS
        }
        switch UserAPI.shared.showUser(userId: userId) {
        case let .success(response):
            UserDAO.shared.updateUsers(users: [response])
            return .SUCCESS
        case let .failure(error):
            if tryAgain && error.errorCode != 404 {
                ConcurrentJobQueue.shared.addJob(job: RefreshUserJob(userIds: [userId]))
            }
            return error.errorCode == 404 ? .ERROR : .START
        }
    }

    private func syncUser(userId: String) -> Bool {
        guard !userId.isEmpty else {
            return false
        }
        guard User.systemUser != userId, userId != currentAccountId, !UserDAO.shared.isExist(userId: userId) else {
            return true
        }

        repeat {
            switch UserAPI.shared.showUser(userId: userId) {
            case let .success(response):
                UserDAO.shared.updateUsers(users: [response])
                return true
            case let .failure(error):
                guard error.errorCode != 404 else {
                    return false
                }
                checkNetworkAndWebSocket()
            }
        } while AccountAPI.shared.didLogin

        return false
    }

    private func processPlainMessage(data: BlazeMessageData) {
        guard data.category.hasPrefix("PLAIN_") else {
            return
        }

        switch data.category {
        case MessageCategory.PLAIN_JSON.rawValue:
            guard let base64Data = Data(base64Encoded: data.data), let plainData = (try? jsonDecoder.decode(TransferPlainData.self, from: base64Data)) else {
                return
            }

            if let user = UserDAO.shared.getUser(userId: data.userId) {
                FileManager.default.writeLog(conversationId: data.conversationId, log: "[ProcessPlainMessage][\(user.fullName)][\(data.category)][\(plainData.action)]...messageId:\(data.messageId)...\(data.createdAt)")
            }

            defer {
                updateRemoteMessageStatus(messageId: data.messageId, status: .READ, createdAt: data.createdAt)
                MessageHistoryDAO.shared.replaceMessageHistory(messageId: data.messageId)
            }

            switch plainData.action {
            case PlainDataAction.RESEND_KEY.rawValue:
                guard !JobDAO.shared.isExist(conversationId: data.conversationId, userId: data.userId, action: .RESEND_KEY) else {
                    return
                }
                guard SignalProtocol.shared.containsSession(recipient: data.userId) else {
                    return
                }
                SendMessageService.shared.sendMessage(conversationId: data.conversationId, userId: data.userId, action: .RESEND_KEY)
            case PlainDataAction.RESEND_MESSAGES.rawValue:
                guard let messageIds = plainData.messages, messageIds.count > 0 else {
                    return
                }
                SendMessageService.shared.resendMessages(conversationId: data.conversationId, userId: data.userId, messageIds: messageIds)
            case PlainDataAction.NO_KEY.rawValue:
                SignalProtocol.shared.deleteRatchetSenderKey(groupId: data.conversationId, senderId: data.userId)
            default:
                break
            }
        case MessageCategory.PLAIN_TEXT.rawValue, MessageCategory.PLAIN_IMAGE.rawValue, MessageCategory.PLAIN_DATA.rawValue, MessageCategory.PLAIN_STICKER.rawValue, MessageCategory.PLAIN_CONTACT.rawValue:
            processDecryptSuccess(data: data, plainText: data.data)
            updateRemoteMessageStatus(messageId: data.messageId, status: .DELIVERED, createdAt: data.createdAt)
        default:
            break
        }
    }

    private func requestResendMessage(conversationId: String, userId: String) {
        let messages: [String] = MessageDAO.shared.findFailedMessages(conversationId: conversationId, userId: userId).reversed()
        guard messages.count > 0 else {
            SignalProtocol.shared.deleteRatchetSenderKey(groupId: conversationId, senderId: userId)
            return
        }
        guard !JobDAO.shared.isExist(conversationId: conversationId, userId: userId, action: .REQUEST_RESEND_MESSAGES) else {
            return
        }

        let transferPlainData = TransferPlainData(action: PlainDataAction.RESEND_MESSAGES.rawValue, messageId: nil, messages: messages)
        let encoded = (try? jsonEncoder.encode(transferPlainData).base64EncodedString()) ?? ""
        let messageId = UUID().uuidString.lowercased()
        let params = BlazeMessageParam(conversationId: conversationId, recipientId: userId, category: MessageCategory.PLAIN_JSON.rawValue, data: encoded, offset: nil, status: MessageStatus.SENDING.rawValue, messageId: messageId, keys: nil, recipients: nil, messages: nil)
        let blazeMessage = BlazeMessage(params: params, action: BlazeMessageAction.createMessage.rawValue)
        SendMessageService.shared.sendMessage(conversationId: conversationId, userId: userId, blazeMessage: blazeMessage, action: .REQUEST_RESEND_MESSAGES)
    }

    private func requestResendKey(conversationId: String, userId: String, messageId: String) {
        guard !JobDAO.shared.isExist(conversationId: conversationId, userId: userId, action: .REQUEST_RESEND_KEY) else {
            return
        }

        let transferPlainData = TransferPlainData(action: PlainDataAction.RESEND_KEY.rawValue, messageId: messageId, messages: nil)
        let encoded = (try? jsonEncoder.encode(transferPlainData).base64EncodedString()) ?? ""
        let messageId = UUID().uuidString.lowercased()
        let params = BlazeMessageParam(conversationId: conversationId, recipientId: userId, category: MessageCategory.PLAIN_JSON.rawValue, data: encoded, offset: nil, status: MessageStatus.SENDING.rawValue, messageId: messageId, keys: nil, recipients: nil, messages: nil)
        let blazeMessage = BlazeMessage(params: params, action: BlazeMessageAction.createMessage.rawValue)
        SendMessageService.shared.sendMessage(conversationId: conversationId, userId: userId, blazeMessage: blazeMessage, action: .REQUEST_RESEND_KEY)
    }

    private func updateRemoteMessageStatus(messageId: String, status: MessageStatus, createdAt: String) {
        SendMessageService.shared.sendAckMessage(messageId: messageId, status: status)
    }
}

extension ReceiveMessageService {

    private func processSystemMessage(data: BlazeMessageData) {
        guard data.category.hasPrefix("SYSTEM_") else {
            return
        }
        
        switch data.category {
        case MessageCategory.SYSTEM_CONVERSATION.rawValue:
            messageDispatchQueue.sync {
                processSystemConversationMessage(data: data)
            }
        case MessageCategory.SYSTEM_ACCOUNT_SNAPSHOT.rawValue:
            processSystemSnapshotMessage(data: data)
        default:
            return
        }
    }

    private func processSystemSnapshotMessage(data: BlazeMessageData) {
        guard let base64Data = Data(base64Encoded: data.data), var snapshot = (try? jsonDecoder.decode(Snapshot.self, from: base64Data)) else {
            return
        }

        if let counterUserId = snapshot.counterUserId {
            checkUser(userId: counterUserId, tryAgain: true)
        }

        switch AssetAPI.shared.asset(assetId: snapshot.assetId) {
        case let .success(asset):
            AssetDAO.shared.insertOrUpdateAssets(assets: [asset])
        case .failure:
            ConcurrentJobQueue.shared.addJob(job: RefreshAssetsJob(assetId: snapshot.assetId))
        }

        snapshot.createdAt = data.createdAt
        SnapshotDAO.shared.replaceSnapshot(snapshot: snapshot)
        MessageDAO.shared.insertMessage(message: Message.createMessage(snapshotMesssage: snapshot, data: data), messageSource: data.source)
        updateRemoteMessageStatus(messageId: data.messageId, status: .READ, createdAt: data.createdAt)
    }

    private func processSystemConversationMessage(data: BlazeMessageData) {
        guard let base64Data = Data(base64Encoded: data.data), let sysMessage = (try? jsonDecoder.decode(SystemConversationData.self, from: base64Data)) else {
            UIApplication.trackError("ReceiveMessageService", action: "processSystemConversationMessage decode data failed")
            return
        }

        let userId = sysMessage.userId ?? data.userId
        let messageId = data.messageId
        var operSuccess = true

        if let participantId = sysMessage.participantId, let user = UserDAO.shared.getUser(userId: participantId) {
            FileManager.default.writeLog(conversationId: data.conversationId, log: "[ProcessSystemMessage][\(user.fullName)][\(sysMessage.action)]...messageId:\(data.messageId)...\(data.createdAt)")
        }

        defer {
            if operSuccess {
                updateRemoteMessageStatus(messageId: messageId, status: .READ, createdAt: data.createdAt)
                if sysMessage.action != SystemConversationAction.UPDATE.rawValue && sysMessage.action != SystemConversationAction.ROLE.rawValue {
                    ConcurrentJobQueue.shared.addJob(job: RefreshGroupIconJob(conversationId: data.conversationId))
                }
            }
        }

        if (userId == User.systemUser) {
            UserDAO.shared.insertSystemUser(userId: userId)
        }

        let message = Message.createMessage(systemMessage: sysMessage.action, participantId: sysMessage.participantId, userId: userId, data: data)
        switch sysMessage.action {
        case SystemConversationAction.ADD.rawValue, SystemConversationAction.JOIN.rawValue:
            guard let participantId = sysMessage.participantId, !participantId.isEmpty, participantId != User.systemUser else {
                handlerSystemMessageDataError(action: sysMessage.action, data: base64Data)
                return
            }
            let status = checkUser(userId: participantId, tryAgain: true)
            operSuccess = ParticipantDAO.shared.addParticipant(message: message, conversationId: data.conversationId, participantId: participantId, updatedAt: data.updatedAt, status: status, source: data.source)

            if participantId != currentAccountId && SignalProtocol.shared.isExistSenderKey(groupId: data.conversationId, senderId: currentAccountId) {
                guard !JobDAO.shared.isExist(conversationId: data.conversationId, userId: participantId, action: .SEND_KEY) else {
                    return
                }
                SendMessageService.shared.sendMessage(conversationId: data.conversationId, userId: participantId, action: .SEND_KEY)
            }
            return
        case SystemConversationAction.REMOVE.rawValue:
            guard let participantId = sysMessage.participantId, !participantId.isEmpty, participantId != User.systemUser else {
                handlerSystemMessageDataError(action: sysMessage.action, data: base64Data)
                return
            }
            SignalProtocol.shared.clearSenderKey(groupId: data.conversationId, senderId: currentAccountId)
            SentSenderKeyDAO.shared.delete(conversationId: data.conversationId)

            operSuccess = ParticipantDAO.shared.removeParticipant(message: message, conversationId: data.conversationId, userId: participantId, source: data.source)
             ConcurrentJobQueue.shared.addJob(job: RefreshUserJob(userIds: [participantId]))
            return
        case SystemConversationAction.EXIT.rawValue:
            guard let participantId = sysMessage.participantId, !participantId.isEmpty, participantId != User.systemUser else {
                handlerSystemMessageDataError(action: sysMessage.action, data: base64Data)
                return
            }

            SignalProtocol.shared.clearSenderKey(groupId: data.conversationId, senderId: currentAccountId)
            SentSenderKeyDAO.shared.delete(conversationId: data.conversationId)

            guard participantId != currentAccountId else {
                ConversationDAO.shared.deleteAndExitConversation(conversationId: data.conversationId, autoNotification: false)
                return
            }

            operSuccess = ParticipantDAO.shared.removeParticipant(message: message, conversationId: data.conversationId, userId: participantId, source: data.source)
            return
        case SystemConversationAction.CREATE.rawValue:
            checkUser(userId: userId, tryAgain: true)
            operSuccess = ConversationDAO.shared.updateConversationOwnerId(conversationId: data.conversationId, ownerId: userId)
        case SystemConversationAction.ROLE.rawValue:
            guard let participantId = sysMessage.participantId, !participantId.isEmpty, participantId != User.systemUser, let role = sysMessage.role else {
                handlerSystemMessageDataError(action: sysMessage.action, data: base64Data)
                return
            }
            operSuccess = ParticipantDAO.shared.updateParticipantRole(message: message, conversationId: data.conversationId, participantId: participantId, role: role, source: data.source)
            return
        case SystemConversationAction.UPDATE.rawValue:
            ConcurrentJobQueue.shared.addJob(job: RefreshConversationJob(conversationId: data.conversationId))
            return
        default:
            break
        }

        MessageDAO.shared.insertMessage(message: message, messageSource: data.source)
    }

    private func handlerSystemMessageDataError(action: String, data: Data) {
        var userInfo = UIApplication.getTrackUserInfo()
        userInfo["category"] = action
        userInfo["SystemConversationData"] = String(data: data, encoding: .utf8) ?? ""
        UIApplication.trackError("ReceiveMessageService", action: "system conversation data error", userInfo: userInfo)
    }
}

extension CiphertextMessage.MessageType {

    static func toString(rawValue: UInt8) -> String {
        switch rawValue {
        case CiphertextMessage.MessageType.preKey.rawValue:
            return "preKey"
        case CiphertextMessage.MessageType.senderKey.rawValue:
            return "senderKey"
        case CiphertextMessage.MessageType.signal.rawValue:
            return "signal"
        case CiphertextMessage.MessageType.distribution.rawValue:
            return "distribution"
        default:
            return "unknown"
        }
    }
}
