package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"runtime/debug"
	"sync"

	"github.com/nknorg/nkn-sdk-go"
)

// NKN Bridge — subprocess that communicates via NDJSON on stdin/stdout.
//
// Build:
//   go build -o nkn_bridge nkn_bridge.go
//
// Protocol:
//   Nim sends a JSON command on stdin (one line), bridge replies on stdout (one line).
//   Received NKN messages are pushed to stdout as {"type":"message",...} lines.

type Request struct {
	ID     string          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type Response struct {
	ID     string `json:"id"`
	Result string `json:"result,omitempty"`
	Data   string `json:"data,omitempty"`
	Src    string `json:"src,omitempty"`
	Error  string `json:"error,omitempty"`
}

type IncomingMessage struct {
	Type       string `json:"type"`
	ClientAddr string `json:"client_addr"`
	Src        string `json:"src"`
	Data       string `json:"data"`
}

var (
	activeClients = make(map[string]*nkn.MultiClient)
	mutex         sync.Mutex
	outMu         sync.Mutex
)

func sendJSON(v interface{}) {
	outMu.Lock()
	defer outMu.Unlock()
	b, _ := json.Marshal(v)
	fmt.Fprintf(os.Stdout, "%s\n", b)
}

func handleGenerateWallet(id string, params json.RawMessage) {
	var p struct {
		Password string `json:"password"`
	}
	json.Unmarshal(params, &p)

	account, err := nkn.NewAccount(nil)
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}
	w, err := nkn.NewWallet(account, &nkn.WalletConfig{Password: p.Password})
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}
	walletJSON, err := w.ToJSON()
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}
	sendJSON(Response{ID: id, Result: walletJSON})
}

func handleGenerateWalletWithSeed(id string, params json.RawMessage) {
	var p struct {
		SeedHex  string `json:"seed_hex"`
		Password string `json:"password"`
	}
	json.Unmarshal(params, &p)

	seed, err := hex.DecodeString(p.SeedHex)
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}
	account, err := nkn.NewAccount(seed)
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}
	w, err := nkn.NewWallet(account, &nkn.WalletConfig{Password: p.Password})
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}
	walletJSON, err := w.ToJSON()
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}
	sendJSON(Response{ID: id, Result: walletJSON})
}

func handleCreateClient(id string, params json.RawMessage) {
	var p struct {
		WalletJSON     string `json:"wallet_json"`
		Password       string `json:"password"`
		Identifier     string `json:"identifier"`
		NumSubClients  int    `json:"num_sub_clients"`
		OriginalClient bool   `json:"original_client"`
	}
	json.Unmarshal(params, &p)

	w, err := nkn.WalletFromJSON(p.WalletJSON, &nkn.WalletConfig{Password: p.Password})
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}

	client, err := nkn.NewMultiClient(w.Account(), p.Identifier, p.NumSubClients, p.OriginalClient, nil)
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}

	<-client.OnConnect.C
	addr := client.Address()

	mutex.Lock()
	activeClients[addr] = client
	mutex.Unlock()

	// Push received messages to stdout
	go func() {
		for msg := range client.OnMessage.C {
			sendJSON(IncomingMessage{
				Type:       "message",
				ClientAddr: addr,
				Src:        msg.Src,
				Data:       string(msg.Data),
			})
		}
	}()

	sendJSON(Response{ID: id, Result: addr})
}

func handleGetAddress(id string, params json.RawMessage) {
	var p struct {
		WalletJSON string `json:"wallet_json"`
		Password   string `json:"password"`
		Identifier string `json:"identifier"`
	}
	json.Unmarshal(params, &p)

	w, err := nkn.WalletFromJSON(p.WalletJSON, &nkn.WalletConfig{Password: p.Password})
	if err != nil {
		sendJSON(Response{ID: id, Error: err.Error()})
		return
	}

	pubKey := hex.EncodeToString(w.PubKey())
	var addr string
	if len(p.Identifier) > 0 {
		addr = p.Identifier + "." + pubKey
	} else {
		addr = pubKey
	}
	sendJSON(Response{ID: id, Result: addr})
}

func handleSendMessage(id string, params json.RawMessage) {
	var p struct {
		ClientAddr        string `json:"client_addr"`
		DestAddr          string `json:"dest_addr"`
		Message           string `json:"message"`
		MaxHoldingSeconds int32  `json:"max_holding_seconds"`
		NoReply           bool   `json:"no_reply"`
	}
	json.Unmarshal(params, &p)

	mutex.Lock()
	client, ok := activeClients[p.ClientAddr]
	mutex.Unlock()

	if !ok {
		sendJSON(Response{ID: id, Error: "client not found"})
		return
	}

	msgConfig := &nkn.MessageConfig{
		MaxHoldingSeconds: p.MaxHoldingSeconds,
		NoReply:           p.NoReply,
	}

	_, err := client.Send(nkn.NewStringArray(p.DestAddr), []byte(p.Message), msgConfig)
	if err != nil {
		sendJSON(Response{ID: id, Error: "send error: " + err.Error()})
		return
	}
	sendJSON(Response{ID: id, Result: "success"})
}

func handleCloseClient(id string, params json.RawMessage) {
	var p struct {
		ClientAddr string `json:"client_addr"`
	}
	json.Unmarshal(params, &p)

	mutex.Lock()
	client, ok := activeClients[p.ClientAddr]
	if ok {
		delete(activeClients, p.ClientAddr)
	}
	mutex.Unlock()

	if !ok {
		sendJSON(Response{ID: id, Error: "client not found"})
		return
	}
	client.Close()
	sendJSON(Response{ID: id, Result: "success"})
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	// Allow large messages (16MB)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			sendJSON(Response{Error: "invalid request: " + err.Error()})
			continue
		}

		func() {
			defer func() {
				if r := recover(); r != nil {
					sendJSON(Response{ID: req.ID, Error: fmt.Sprintf("panic: %v\n%s", r, debug.Stack())})
				}
			}()
			switch req.Method {
			case "generate_wallet":
				handleGenerateWallet(req.ID, req.Params)
			case "generate_wallet_with_seed":
				handleGenerateWalletWithSeed(req.ID, req.Params)
			case "create_client":
				handleCreateClient(req.ID, req.Params)
			case "get_address":
				handleGetAddress(req.ID, req.Params)
			case "send_message":
				handleSendMessage(req.ID, req.Params)
			case "close_client":
				handleCloseClient(req.ID, req.Params)
			default:
				sendJSON(Response{ID: req.ID, Error: "unknown method: " + req.Method})
			}
		}()
	}

	// stdin closed — clean up all clients
	mutex.Lock()
	for addr, client := range activeClients {
		client.Close()
		delete(activeClients, addr)
	}
	mutex.Unlock()
}
