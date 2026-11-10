package main

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// backend stands in for the Swift loopback listener.
func backend(t *testing.T, h http.HandlerFunc) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: h}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return ln.Addr().(*net.TCPAddr).Port
}

func TestProxyForwardsPathBodyAndLength(t *testing.T) {
	var gotPath, gotBody, gotLen, gotTE, gotXFF string
	port := backend(t, func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotPath, gotBody = r.URL.Path, string(b)
		gotLen = strconv.FormatInt(r.ContentLength, 10)
		gotTE = strings.Join(r.TransferEncoding, ",")
		gotXFF = r.Header.Get("X-Forwarded-For")
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ok":true}`)
	})
	front := httptest.NewServer(proxy(port))
	defer front.Close()

	// A chunked upload (unknown length) must arrive with a Content-Length.
	req, _ := http.NewRequest("POST", front.URL+"/the-secret/mcp", io.NopCloser(strings.NewReader(`{"a":1}`)))
	req.ContentLength = -1
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	if resp.StatusCode != 200 || string(body) != `{"ok":true}` {
		t.Fatalf("response: %d %q", resp.StatusCode, body)
	}
	if gotPath != "/the-secret/mcp" || gotBody != `{"a":1}` {
		t.Fatalf("forwarded path %q body %q", gotPath, gotBody)
	}
	if gotLen != "7" || gotTE != "" {
		t.Fatalf("content-length %s, transfer-encoding %q", gotLen, gotTE)
	}
	if gotXFF != "" {
		t.Fatalf("X-Forwarded-For leaked: %q", gotXFF)
	}
}

func TestProxyPassesBackend404Through(t *testing.T) {
	port := backend(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(404)
		io.WriteString(w, "404 page not found\n")
	})
	front := httptest.NewServer(proxy(port))
	defer front.Close()
	resp, _ := http.Get(front.URL + "/wrong/mcp")
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 404 || string(body) != "404 page not found\n" {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
}

func TestBackendDownLooksLikeAMiss(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close() // nothing listens here now
	front := httptest.NewServer(proxy(port))
	defer front.Close()
	resp, err := http.Post(front.URL+"/s/mcp", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 404 || string(body) != "404 page not found\n" {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
}

func TestOversizedBodyIsRejected(t *testing.T) {
	called := false
	port := backend(t, func(http.ResponseWriter, *http.Request) { called = true })
	front := httptest.NewServer(proxy(port))
	defer front.Close()
	resp, err := http.Post(front.URL+"/s/mcp", "application/json", strings.NewReader(strings.Repeat("x", maxBody+10)))
	if err == nil {
		resp.Body.Close()
		if resp.StatusCode != 404 {
			t.Fatalf("status %d", resp.StatusCode)
		}
	}
	if called {
		t.Fatal("oversized body reached the backend")
	}
}

func TestStartValidatesArguments(t *testing.T) {
	if err := start("", "h", "", 8220); err == nil {
		t.Fatal("empty state dir accepted")
	}
	if err := start(t.TempDir(), "", "", 8220); err == nil {
		t.Fatal("empty hostname accepted")
	}
	mu.Lock()
	s := cur.State
	mu.Unlock()
	if s != "stopped" {
		t.Fatalf("state %q after rejected start", s)
	}
}
