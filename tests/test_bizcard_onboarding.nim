import std/[unittest, json, os, tables, asyncdispatch, times, strutils]
import ../src/nimclaw/agent/[social_sensors, invites, context]
import ../src/nimclaw/tools/[types, registry, invite]

suite "Business Card Onboarding Flow":
  
  setup:
    let tempWs = getTempDir() / "nimclaw_test_bizcard"
    createDir(tempWs)
    removeFile(tempWs / "RELATIONS.json")
    removeFile(tempWs / "INVITES.json")

  teardown:
    let tempWs = getTempDir() / "nimclaw_test_bizcard"
    if dirExists(tempWs):
      removeDir(tempWs)

  test "Business Card Pin Code Redemption":
    let tool = newRedeemInviteTool()
    let testHome = getTempDir() / "nimclaw_fake_home_redeem"
    let testWs = testHome / ".nimclaw" / "workspace"
    createDir(testWs)
    
    # Mock INVITES.json in the fake home
    let code = "A4B-9X2"
    var allInvites = initTable[string, InviteConstraint]()
    allInvites[code] = InviteConstraint(
      code: code,
      agentName: "sales_bot",
      customerName: "Alice",
      role: "customer",
      maxUses: 1,
      expiry: 0,
      pinless: false
    )
    saveInvites(testWs, allInvites)

    # Alice is unknown initially
    var relations = loadRelations(testWs)
    let (uid1, agent1) = relations.resolveUser("nmobile", "alice_raw_nkn")
    check uid1 == "alice_raw_nkn"
    check agent1 == ""
    
    # Alice sends code, Agent calls tool
    let oldHome = getEnv("HOME")
    putEnv("HOME", testHome)
    defer: putEnv("HOME", oldHome)

    tool.setContext("nmobile", "alice_raw_nkn", "sess_1", "alice_raw_nkn", "sales_bot")
    let args = {"code": %code}.toTable
    
    let result = waitFor tool.execute(args)
    check result.contains("Successfully redeemed")

    # Verify Alice is now a Customer in the fake relations
    let relations2 = loadRelations(testWs)
    let (uid2, agent2) = relations2.resolveUser("nmobile", "alice_raw_nkn")
    check uid2.startsWith("customer_")
    check agent2 == "sales_bot"
    check relations2[uid2].role == urCustomer
    check "alice_raw_nkn" in relations2[uid2].identifiers["nmobile"]

    # Verify Pin Code is gone (single use)
    let invites2 = loadInvites(testWs)
    check invites2.hasKey(code) == false

    removeDir(testHome)

  test "Business Card Pinless Auto-Redemption Logic":
    let testWs = getTempDir() / "nimclaw_test_pinless_auto"
    createDir(testWs)
    
    # 1. Setup pinless invite
    var allInvites = initTable[string, InviteConstraint]()
    allInvites["PUBLIC"] = InviteConstraint(
      code: "PUBLIC",
      agentName: "news_bot",
      customerName: "Public User",
      role: "customer",
      maxUses: -1,
      expiry: 0,
      pinless: true
    )
    saveInvites(testWs, allInvites)

    # 2. Simulate the logic inside AgentLoop.runAgentLoop
    let channel = "nmobile"
    let senderID = "random_stranger"
    let recipientID = "news_bot"
    
    var relations = loadRelations(testWs)
    var (logicalUID, _) = relations.resolveUser(channel, senderID)
    check logicalUID == senderID # Stranger
    
    # Guest logic inside loop
    if logicalUID == senderID:
      let invites = loadInvites(testWs)
      for code, inv in invites.pairs:
        if inv.pinless and inv.agentName == recipientID:
          let newID = "customer_pinless_" & senderID
          var rel = Relationship(userID: newID, agentName: inv.agentName, role: urCustomer, identifiers: {channel: @[senderID]}.toTable)
          relations[newID] = rel
          saveRelations(testWs, relations)
          logicalUID = newID
          break
    
    check logicalUID == "customer_pinless_random_stranger"
    let relations2 = loadRelations(testWs)
    check relations2.hasKey("customer_pinless_random_stranger")
    check relations2["customer_pinless_random_stranger"].agentName == "news_bot"
    
    removeDir(testWs)

