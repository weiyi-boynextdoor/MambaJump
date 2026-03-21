package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestScoreLifecycleAndStats(t *testing.T) {
	app := newTestServer(t)

	createBody := map[string]any{
		"athlete_name":   "Yiwei",
		"jump_height_cm": 58.2,
		"airtime_ms":     700,
		"source_type":    "live_camera",
	}
	resp := performJSON(t, app.routes(), http.MethodPost, "/api/scores", createBody)
	if resp.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", resp.Code, resp.Body.String())
	}

	var created score
	if err := json.Unmarshal(resp.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode created score: %v", err)
	}

	listResp := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/scores", nil)
	app.routes().ServeHTTP(listResp, req)
	if listResp.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", listResp.Code, listResp.Body.String())
	}

	statsResp := httptest.NewRecorder()
	statsReq := httptest.NewRequest(http.MethodGet, "/api/stats", nil)
	app.routes().ServeHTTP(statsResp, statsReq)
	if statsResp.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", statsResp.Code, statsResp.Body.String())
	}

	var stats statsResponse
	if err := json.Unmarshal(statsResp.Body.Bytes(), &stats); err != nil {
		t.Fatalf("decode stats: %v", err)
	}

	if stats.TotalAttempts != 1 {
		t.Fatalf("expected 1 attempt, got %d", stats.TotalAttempts)
	}
	if stats.BestJumpCM != created.JumpHeightCM {
		t.Fatalf("expected best jump %.1f, got %.1f", created.JumpHeightCM, stats.BestJumpCM)
	}
}

func TestUploadAndAttachToScore(t *testing.T) {
	app := newTestServer(t)

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "jump.mov")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := part.Write([]byte("fake-video-data")); err != nil {
		t.Fatalf("write multipart body: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}

	uploadReq := httptest.NewRequest(http.MethodPost, "/api/uploads", &body)
	uploadReq.Header.Set("Content-Type", writer.FormDataContentType())
	uploadResp := httptest.NewRecorder()
	app.routes().ServeHTTP(uploadResp, uploadReq)
	if uploadResp.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", uploadResp.Code, uploadResp.Body.String())
	}

	var asset uploadAsset
	if err := json.Unmarshal(uploadResp.Body.Bytes(), &asset); err != nil {
		t.Fatalf("decode upload response: %v", err)
	}

	createBody := map[string]any{
		"jump_height_cm": 61.3,
		"media_asset_id": asset.ID,
	}
	scoreResp := performJSON(t, app.routes(), http.MethodPost, "/api/scores", createBody)
	if scoreResp.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", scoreResp.Code, scoreResp.Body.String())
	}

	var created score
	if err := json.Unmarshal(scoreResp.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode score: %v", err)
	}
	if created.OriginalVideo == nil {
		t.Fatal("expected uploaded media metadata to be attached to the score")
	}

	uploadedPath := filepath.Join(app.store.uploadDir, asset.StoredName)
	if _, err := os.Stat(uploadedPath); err != nil {
		t.Fatalf("expected uploaded file at %s: %v", uploadedPath, err)
	}
}

func newTestServer(t *testing.T) *server {
	t.Helper()

	baseDir := t.TempDir()
	dataFile := filepath.Join(baseDir, "data", "store.json")
	uploadDir := filepath.Join(baseDir, "uploads")

	store, err := newStore(dataFile, uploadDir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	return newServer(store)
}

func performJSON(t *testing.T, handler http.Handler, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()

	var payload bytes.Buffer
	if err := json.NewEncoder(&payload).Encode(body); err != nil {
		t.Fatalf("encode JSON body: %v", err)
	}

	req := httptest.NewRequest(method, path, &payload)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	return resp
}
