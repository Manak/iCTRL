// Package main is the Tailscale side of the Claude bridge, built as a C
// archive and linked into the iCTRL runner.
//
// It joins the tailnet as its own device (userspace networking, no VPN
// profile), serves port 443 through Tailscale Funnel, and forwards every
// request to the bridge's MCP listener on 127.0.0.1. It contains no MCP logic
// and no authentication: both stay in Swift, behind the loopback listener.
//
// TLS ends here, on the phone. Tailscale's Funnel relays see ciphertext only,
// so the URL secret in the request path never reaches them.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"tailscale.com/tsnet"
)

// maxBody matches the loopback listener's limit.
const maxBody = 1 << 20

type status struct {
	// stopped | starting | needs_login | running | error
	State string `json:"state"`
	// Public host name of the endpoint, once known (for example
	// "ictrl-phone.tail1234.ts.net"). Never includes the URL secret.
	Host  string `json:"host,omitempty"`
	Error string `json:"error,omitempty"`
}

var (
	mu     sync.Mutex
	cur    = status{State: "stopped"}
	server *tsnet.Server
	httpd  *http.Server
	cancel context.CancelFunc
)

func setStatus(s status) {
	mu.Lock()
	cur = s
	mu.Unlock()
}

// start brings the node and the Funnel listener up in the background.
func start(dir, hostname, authKey string, targetPort int) error {
	mu.Lock()
	defer mu.Unlock()
	if server != nil {
		return errors.New("already started")
	}
	if dir == "" || hostname == "" || targetPort <= 0 {
		return errors.New("state directory, hostname and target port are required")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("state directory: %w", err)
	}
	// Do not upload this node's logs to Tailscale's log service.
	os.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")

	srv := &tsnet.Server{
		Dir:      dir,
		Hostname: hostname,
		AuthKey:  authKey,
		// tsnet's own logs are verbose and can carry peer details. Dropped.
		Logf:     func(string, ...any) {},
		UserLogf: func(string, ...any) {},
	}
	ctx, stop := context.WithCancel(context.Background())
	server, cancel = srv, stop
	cur = status{State: "starting"}
	go run(ctx, srv, targetPort)
	return nil
}

func run(ctx context.Context, srv *tsnet.Server, targetPort int) {
	fail := func(err error) {
		if ctx.Err() != nil {
			return // stopping; not an error
		}
		state := "error"
		msg := err.Error()
		if strings.Contains(msg, "auth") && strings.Contains(msg, "key") ||
			strings.Contains(msg, "NeedsLogin") || strings.Contains(msg, "not logged in") {
			state = "needs_login"
		}
		setStatus(status{State: state, Error: msg})
	}

	upCtx, done := context.WithTimeout(ctx, 90*time.Second)
	st, err := srv.Up(upCtx)
	done()
	if err != nil {
		fail(fmt.Errorf("joining the tailnet: %w", err))
		return
	}
	host := ""
	if st != nil && st.Self != nil {
		host = strings.TrimSuffix(st.Self.DNSName, ".")
	}
	if domains := srv.CertDomains(); len(domains) > 0 {
		host = domains[0]
	}

	// FunnelOnly: reachable from the internet through Funnel, and not from
	// other devices on the tailnet.
	ln, err := srv.ListenFunnel("tcp", ":443", tsnet.FunnelOnly())
	if err != nil {
		fail(fmt.Errorf("starting Funnel: %w", err))
		return
	}

	h := &http.Server{
		Handler:           proxy(targetPort),
		ReadHeaderTimeout: 15 * time.Second,
		ReadTimeout:       30 * time.Second,
		// Tool calls can take a while (typing, settling); leave room.
		WriteTimeout: 150 * time.Second,
		IdleTimeout:  60 * time.Second,
		// Never log: error lines can include request details.
		ErrorLog: log.New(io.Discard, "", 0),
	}
	mu.Lock()
	if ctx.Err() != nil {
		mu.Unlock()
		ln.Close()
		return
	}
	httpd = h
	cur = status{State: "running", Host: host}
	mu.Unlock()

	if err := h.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fail(fmt.Errorf("serving: %w", err))
	}
}

// proxy forwards a request to the loopback MCP listener unchanged, except
// that the body is read fully first so it always carries a Content-Length.
func proxy(targetPort int) http.Handler {
	target := &url.URL{Scheme: "http", Host: fmt.Sprintf("127.0.0.1:%d", targetPort)}
	rp := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			// No forwarding headers: the listener treats everything alike.
			r.Out.Header.Del("X-Forwarded-For")
			r.Out.Header.Del("Forwarded")
		},
		Transport: &http.Transport{
			DialContext:           (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
			DisableKeepAlives:     true, // the listener answers one request per connection
			ResponseHeaderTimeout: 140 * time.Second,
		},
		ErrorLog: log.New(io.Discard, "", 0),
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			// The listener is down or slow. Same generic answer as a miss.
			notFound(w)
		},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		if err != nil {
			notFound(w)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
		r.TransferEncoding = nil
		rp.ServeHTTP(w, r)
	})
}

func notFound(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNotFound)
	io.WriteString(w, "404 page not found\n")
}

func stopAll() {
	mu.Lock()
	h, srv, stop := httpd, server, cancel
	httpd, server, cancel = nil, nil, nil
	cur = status{State: "stopped"}
	mu.Unlock()

	if stop != nil {
		stop()
	}
	if h != nil {
		ctx, done := context.WithTimeout(context.Background(), 2*time.Second)
		h.Shutdown(ctx)
		done()
	}
	if srv != nil {
		srv.Close() // leaves the tailnet session; Funnel stops answering
	}
}

// MARK: C API

//export ClaudeBridgeTSStart
func ClaudeBridgeTSStart(dir, hostname, authKey *C.char, targetPort C.int) *C.char {
	if err := start(C.GoString(dir), C.GoString(hostname), C.GoString(authKey), int(targetPort)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export ClaudeBridgeTSStop
func ClaudeBridgeTSStop() { stopAll() }

// ClaudeBridgeTSStatus returns a JSON status string. The caller frees it.
//
//export ClaudeBridgeTSStatus
func ClaudeBridgeTSStatus() *C.char {
	mu.Lock()
	b, _ := json.Marshal(cur)
	mu.Unlock()
	return C.CString(string(b))
}

func main() {}
