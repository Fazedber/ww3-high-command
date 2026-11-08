-- Port of OpenFrontIO src/core/game/AllianceImpl.ts and AllianceRequestImpl.ts.

local AllianceImpl = {}
AllianceImpl.__index = AllianceImpl

function AllianceImpl.new(mg, requestor, recipient, createdAt: number, id: number)
	return setmetatable({
		mg = mg,
		requestor_ = requestor,
		recipient_ = recipient,
		createdAt_ = createdAt,
		id_ = id,
		extensionRequestedRequestor_ = false,
		extensionRequestedRecipient_ = false,
		expiresAt_ = createdAt + mg:config():allianceDuration(),
	}, AllianceImpl)
end

function AllianceImpl:other(player)
	if self.requestor_ == player then
		return self.recipient_
	end
	return self.requestor_
end
function AllianceImpl:requestor()
	return self.requestor_
end
function AllianceImpl:recipient()
	return self.recipient_
end
function AllianceImpl:createdAt(): number
	return self.createdAt_
end
function AllianceImpl:expire()
	self.mg:expireAlliance(self)
end
function AllianceImpl:addExtensionRequest(player)
	if self.requestor_ == player then
		self.extensionRequestedRequestor_ = true
	elseif self.recipient_ == player then
		self.extensionRequestedRecipient_ = true
	end
	self.mg:addUpdate({ type = "AllianceExtension", playerID = player:smallID(), allianceID = self.id_ })
end
function AllianceImpl:bothAgreedToExtend(): boolean
	return self.extensionRequestedRequestor_ and self.extensionRequestedRecipient_
end
-- One side asked to extend and the other has not (yet).
function AllianceImpl:onlyOneAgreedToExtend(): boolean
	return self.extensionRequestedRequestor_ ~= self.extensionRequestedRecipient_
end
function AllianceImpl:agreedToExtend(player): boolean
	return (self.requestor_ == player and self.extensionRequestedRequestor_) or (self.recipient_ == player and self.extensionRequestedRecipient_)
end
function AllianceImpl:id(): number
	return self.id_
end
function AllianceImpl:extend()
	self.extensionRequestedRequestor_ = false
	self.extensionRequestedRecipient_ = false
	self.expiresAt_ = self.mg:ticks() + self.mg:config():allianceDuration()
end
function AllianceImpl:expiresAt(): number
	return self.expiresAt_
end

-- AllianceRequestImpl ----------------------------------------------------------------

local AllianceRequestImpl = {}
AllianceRequestImpl.__index = AllianceRequestImpl

function AllianceRequestImpl.new(requestor, recipient, tickCreated: number, game)
	return setmetatable({ requestor_ = requestor, recipient_ = recipient, tickCreated = tickCreated, game = game, status_ = "pending" }, AllianceRequestImpl)
end
function AllianceRequestImpl:status(): string
	return self.status_
end
function AllianceRequestImpl:requestor()
	return self.requestor_
end
function AllianceRequestImpl:recipient()
	return self.recipient_
end
function AllianceRequestImpl:createdAt(): number
	return self.tickCreated
end
function AllianceRequestImpl:accept()
	self.status_ = "accepted"
	self.game:acceptAllianceRequest(self)
end
function AllianceRequestImpl:reject()
	self.status_ = "rejected"
	self.game:rejectAllianceRequest(self)
end
function AllianceRequestImpl:toUpdate()
	return {
		type = "AllianceRequest",
		requestorID = self.requestor_:smallID(),
		recipientID = self.recipient_:smallID(),
		createdAt = self.tickCreated,
	}
end

return { AllianceImpl = AllianceImpl, AllianceRequestImpl = AllianceRequestImpl }
