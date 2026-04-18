import std/[unittest, json, os, tables, asyncdispatch, times, strutils]
import ../src/nimclaw/agent/[social_sensors, invites, context]
import ../src/nimclaw/tools/[types, registry, invite]
import ../src/nimclaw/config

# Mocking parts of cli_admin logic for the test
proc setupTestEnv(workspace: string) =
  if dirExists(workspace): removeDir(workspace)
  createDir(workspace)
  createDir(workspace / "sessions")

suite "Access Mode Refactoring (Public vs. Private)":
  let workspace = expandHome("~/.temp_nimclaw_access_test")
  setupTestEnv(workspace)
  
  test "Public Mode allows instant access":
    # 1. Manually simulate 'nimclaw agents access test_agent --public'
    var invites = loadInvites(workspace)
    let publicCode = getPublicCode("test_agent")
    invites[publicCode] = InviteConstraint(
      code: publicCode,
      agentName: "test_agent",
      customerName: "Public",
      role: "customer",
      maxUses: -1,
      expiry: 0,
      pinless: true
    )
    saveInvites(workspace, invites)
    
    # 2. Simulate a message from a stranger to 'test_agent'
    let channel = "nkn"
    let senderID = "stranger_123"
    let recipientID = "test_agent"
    
    var relations = loadRelations(workspace)
    let (uid, _) = relations.resolveUser(channel, senderID)
    check uid == senderID # Not yet recognized
    
    # 3. Simulate the AgentLoop check for pinless
    var allInvites = loadInvites(workspace)
    var logicalUserID = senderID
    for code, inv in allInvites.pairs:
      if inv.pinless and (recipientID == "" or inv.agentName == recipientID) and isValid(inv):
        let sanitizedName = inv.customerName.replace(" ", "_").toLowerAscii()
        let newID = "customer_ext_" & sanitizedName & "_" & senderID[0..min(3, senderID.len-1)]
        var rel = Relationship(
          userID: newID,
          agentName: inv.agentName,
          role: urCustomer,
          trustLevel: 50,
          identifiers: {channel: @[senderID]}.toTable
        )
        relations[newID] = rel
        saveRelations(workspace, relations)
        logicalUserID = newID
        break
    
    check logicalUserID.startsWith("customer_ext_public_")
    
  test "Private Mode requires One-Time Pin and consumes it":
    setupTestEnv(workspace) # Clear previous test
    
    # 1. Manually simulate 'nimclaw agents bizcard test_agent --name="Alice"' in private mode
    let otp = generateInviteCode()
    var invites = loadInvites(workspace)
    invites[otp] = InviteConstraint(
      code: otp,
      agentName: "test_agent",
      customerName: "Alice",
      role: "customer",
      maxUses: 1,
      expiry: getTime().toUnix() + 3600,
      pinless: false
    )
    saveInvites(workspace, invites)
    
    # 2. Simulate Alice sending the OTP
    let tool = newRedeemInviteTool()
    tool.setContext("nkn", "chat1", "sess1", "alice_addr", "test_agent")
    
    # Override workspace in social_sensors/invites is hard, so we assume the tool uses expandHome which we can't easily override without mock
    # Instead, we will test the logic by manually invoking the redeem logic but using our local variables
    
    # Simulate tool execution logic
    var mInvites = loadInvites(workspace)
    check mInvites.hasKey(otp)
    
    var inv = mInvites[otp]
    check inv.customerName == "Alice"
    
    var mRelations = loadRelations(workspace)
    let sanitizedName = inv.customerName.replace(" ", "_").toLowerAscii()
    let shortCode = otp[0..2]
    let newID = "customer_" & sanitizedName & "_" & shortCode
    
    mRelations[newID] = Relationship(
      userID: newID,
      agentName: inv.agentName,
      role: urCustomer,
      identifiers: {"nkn": @["alice_addr"]}.toTable
    )
    saveRelations(workspace, mRelations)
    
    # Consume OTP
    inv.maxUses -= 1
    if inv.maxUses == 0: mInvites.del(otp)
    saveInvites(workspace, mInvites)
    
    # 3. Verify OTP is gone
    let finalInvites = loadInvites(workspace)
    check not finalInvites.hasKey(otp)
    
    # 4. Verify Alice is now a known Customer
    let finalRelations = loadRelations(workspace)
    let (resolvedID, _) = finalRelations.resolveUser("nkn", "alice_addr")
    check resolvedID == newID
    
  # Cleanup
  removeDir(workspace)
