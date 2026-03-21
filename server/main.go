package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultPort      = "8080"
	maxUploadSize    = 200 << 20
	defaultDataFile  = "data/store.json"
	defaultUploadDir = "uploads"
	timeFormat       = time.RFC3339
)

type score struct {
	ID            string     `json:"id"`
	AthleteName   string     `json:"athlete_name"`
	JumpHeightCM  float64    `json:"jump_height_cm"`
	AirTimeMS     int        `json:"airtime_ms,omitempty"`
	SourceType    string     `json:"source_type,omitempty"`
	Notes         string     `json:"notes,omitempty"`
	CapturedAt    time.Time  `json:"captured_at"`
	CreatedAt     time.Time  `json:"created_at"`
	MediaAssetID  string     `json:"media_asset_id,omitempty"`
	OriginalVideo *videoInfo `json:"original_video,omitempty"`
}

type videoInfo struct {
	Filename    string `json:"filename"`
	ContentType string `json:"content_type"`
	SizeBytes   int64  `json:"size_bytes"`
	URL         string `json:"url"`
}

type uploadAsset struct {
	ID           string    `json:"id"`
	OriginalName string    `json:"original_name"`
	StoredName   string    `json:"stored_name"`
	ContentType  string    `json:"content_type"`
	SizeBytes    int64     `json:"size_bytes"`
	URL          string    `json:"url"`
	UploadedAt   time.Time `json:"uploaded_at"`
}

type statsResponse struct {
	TotalAttempts     int      `json:"total_attempts"`
	BestJumpCM        float64  `json:"best_jump_cm"`
	AverageJumpCM     float64  `json:"average_jump_cm"`
	LatestJumpCM      float64  `json:"latest_jump_cm"`
	BestAthleteName   string   `json:"best_athlete_name,omitempty"`
	RecentScoreIDs    []string `json:"recent_score_ids"`
	LastCapturedAt    string   `json:"last_captured_at,omitempty"`
	UploadedFileCount int      `json:"uploaded_file_count"`
}

type store struct {
	mu        sync.RWMutex
	path      string
	scores    []score
	uploads   []uploadAsset
	uploadDir string
}

type diskState struct {
	Scores  []score       `json:"scores"`
	Uploads []uploadAsset `json:"uploads"`
}

type createScoreRequest struct {
	AthleteName  string  `json:"athlete_name"`
	JumpHeightCM float64 `json:"jump_height_cm"`
	AirTimeMS    int     `json:"airtime_ms"`
	SourceType   string  `json:"source_type"`
	Notes        string  `json:"notes"`
	CapturedAt   string  `json:"captured_at"`
	MediaAssetID string  `json:"media_asset_id"`
}

func main() {
	port := envOr("PORT", defaultPort)
	dataFile := envOr("MAMBAJUMP_DATA_FILE", defaultDataFile)
	uploadDir := envOr("MAMBAJUMP_UPLOAD_DIR", defaultUploadDir)

	appStore, err := newStore(dataFile, uploadDir)
	if err != nil {
		log.Fatalf("failed to initialize store: %v", err)
	}

	server := newServer(appStore)

	log.Printf("MambaJump server listening on http://localhost:%s", port)
	log.Printf("data file: %s", dataFile)
	log.Printf("upload dir: %s", uploadDir)

	if err := http.ListenAndServe(":"+port, server.routes()); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
}

type server struct {
	store *store
}

func newServer(s *store) *server {
	return &server{
		store: s,
	}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /api/scores", s.handleListScores)
	mux.HandleFunc("POST /api/scores", s.handleCreateScore)
	mux.HandleFunc("GET /api/scores/{id}", s.handleGetScore)
	mux.HandleFunc("DELETE /api/scores/{id}", s.handleDeleteScore)
	mux.HandleFunc("GET /api/stats", s.handleStats)
	mux.HandleFunc("GET /api/uploads", s.handleListUploads)
	mux.HandleFunc("POST /api/uploads", s.handleUploadFile)
	mux.Handle("GET /uploads/", http.StripPrefix("/uploads/", http.FileServer(http.Dir(s.store.uploadDir))))

	return withCORS(withLogging(mux))
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ok",
		"time":   time.Now().UTC().Format(timeFormat),
	})
}

func (s *server) handleListScores(w http.ResponseWriter, r *http.Request) {
	limit := 0
	if rawLimit := r.URL.Query().Get("limit"); rawLimit != "" {
		parsed, err := strconv.Atoi(rawLimit)
		if err != nil || parsed < 0 {
			writeError(w, http.StatusBadRequest, "limit must be a positive integer")
			return
		}
		limit = parsed
	}

	scores := s.store.listScores(limit)
	writeJSON(w, http.StatusOK, map[string]any{
		"scores": scores,
		"count":  len(scores),
	})
}

func (s *server) handleCreateScore(w http.ResponseWriter, r *http.Request) {
	var req createScoreRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	capturedAt := time.Now().UTC()
	if req.CapturedAt != "" {
		parsed, err := time.Parse(timeFormat, req.CapturedAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "captured_at must be RFC3339")
			return
		}
		capturedAt = parsed.UTC()
	}

	if req.JumpHeightCM <= 0 {
		writeError(w, http.StatusBadRequest, "jump_height_cm must be greater than zero")
		return
	}

	newScore := score{
		ID:           randomID("score"),
		AthleteName:  strings.TrimSpace(req.AthleteName),
		JumpHeightCM: req.JumpHeightCM,
		AirTimeMS:    req.AirTimeMS,
		SourceType:   strings.TrimSpace(req.SourceType),
		Notes:        strings.TrimSpace(req.Notes),
		CapturedAt:   capturedAt,
		CreatedAt:    time.Now().UTC(),
		MediaAssetID: strings.TrimSpace(req.MediaAssetID),
	}

	if newScore.AthleteName == "" {
		newScore.AthleteName = "Personal"
	}

	if req.MediaAssetID != "" {
		asset, ok := s.store.getUpload(req.MediaAssetID)
		if !ok {
			writeError(w, http.StatusBadRequest, "media_asset_id does not exist")
			return
		}
		newScore.OriginalVideo = &videoInfo{
			Filename:    asset.OriginalName,
			ContentType: asset.ContentType,
			SizeBytes:   asset.SizeBytes,
			URL:         asset.URL,
		}
	}

	if err := s.store.addScore(newScore); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save score")
		return
	}

	writeJSON(w, http.StatusCreated, newScore)
}

func (s *server) handleGetScore(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	item, ok := s.store.getScore(id)
	if !ok {
		writeError(w, http.StatusNotFound, "score not found")
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (s *server) handleDeleteScore(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.store.deleteScore(id) {
		writeError(w, http.StatusNotFound, "score not found")
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleStats(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.store.stats())
}

func (s *server) handleListUploads(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"uploads": s.store.listUploads(),
		"count":   len(s.store.listUploads()),
	})
}

func (s *server) handleUploadFile(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadSize)
	if err := r.ParseMultipartForm(maxUploadSize); err != nil {
		writeError(w, http.StatusBadRequest, "failed to parse multipart upload")
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing multipart file field named 'file'")
		return
	}
	defer file.Close()

	asset, err := s.store.saveUpload(file, header)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save upload")
		return
	}

	writeJSON(w, http.StatusCreated, asset)
}

func newStore(path, uploadDir string) (*store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(uploadDir, 0o755); err != nil {
		return nil, err
	}

	s := &store{
		path:      path,
		uploadDir: uploadDir,
	}

	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *store) load() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	contents, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			s.scores = []score{}
			s.uploads = []uploadAsset{}
			return s.persistLocked()
		}
		return err
	}

	var state diskState
	if len(contents) > 0 {
		if err := json.Unmarshal(contents, &state); err != nil {
			return fmt.Errorf("decode store: %w", err)
		}
	}

	s.scores = state.Scores
	s.uploads = state.Uploads
	s.sortScoresLocked()
	return nil
}

func (s *store) persistLocked() error {
	state := diskState{
		Scores:  s.scores,
		Uploads: s.uploads,
	}

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0o644)
}

func (s *store) sortScoresLocked() {
	slices.SortFunc(s.scores, func(a, b score) int {
		if a.CapturedAt.After(b.CapturedAt) {
			return -1
		}
		if a.CapturedAt.Before(b.CapturedAt) {
			return 1
		}
		if a.CreatedAt.After(b.CreatedAt) {
			return -1
		}
		if a.CreatedAt.Before(b.CreatedAt) {
			return 1
		}
		return strings.Compare(a.ID, b.ID)
	})
}

func (s *store) addScore(item score) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.scores = append(s.scores, item)
	s.sortScoresLocked()
	return s.persistLocked()
}

func (s *store) listScores(limit int) []score {
	s.mu.RLock()
	defer s.mu.RUnlock()

	scores := append([]score(nil), s.scores...)
	if limit > 0 && limit < len(scores) {
		scores = scores[:limit]
	}
	return scores
}

func (s *store) getScore(id string) (score, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for _, item := range s.scores {
		if item.ID == id {
			return item, true
		}
	}
	return score{}, false
}

func (s *store) deleteScore(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i, item := range s.scores {
		if item.ID == id {
			s.scores = append(s.scores[:i], s.scores[i+1:]...)
			if err := s.persistLocked(); err != nil {
				log.Printf("failed to persist after delete: %v", err)
			}
			return true
		}
	}
	return false
}

func (s *store) stats() statsResponse {
	s.mu.RLock()
	defer s.mu.RUnlock()

	resp := statsResponse{
		TotalAttempts:     len(s.scores),
		RecentScoreIDs:    []string{},
		UploadedFileCount: len(s.uploads),
	}

	if len(s.scores) == 0 {
		return resp
	}

	total := 0.0
	best := s.scores[0]
	resp.LatestJumpCM = s.scores[0].JumpHeightCM
	resp.LastCapturedAt = s.scores[0].CapturedAt.Format(timeFormat)

	for i, item := range s.scores {
		total += item.JumpHeightCM
		if item.JumpHeightCM > best.JumpHeightCM {
			best = item
		}
		if i < 5 {
			resp.RecentScoreIDs = append(resp.RecentScoreIDs, item.ID)
		}
	}

	resp.BestJumpCM = best.JumpHeightCM
	resp.BestAthleteName = best.AthleteName
	resp.AverageJumpCM = total / float64(len(s.scores))
	return resp
}

func (s *store) saveUpload(file multipart.File, header *multipart.FileHeader) (uploadAsset, error) {
	sniffBuffer := make([]byte, 512)
	n, err := file.Read(sniffBuffer)
	if err != nil && !errors.Is(err, io.EOF) {
		return uploadAsset{}, err
	}

	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return uploadAsset{}, err
	}

	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = http.DetectContentType(sniffBuffer[:n])
	}

	ext := strings.ToLower(filepath.Ext(header.Filename))
	if ext == "" {
		ext = extensionFromContentType(contentType)
	}

	storedName := randomID("upload") + ext
	dstPath := filepath.Join(s.uploadDir, storedName)
	dstFile, err := os.Create(dstPath)
	if err != nil {
		return uploadAsset{}, err
	}
	defer dstFile.Close()

	size, err := io.Copy(dstFile, file)
	if err != nil {
		return uploadAsset{}, err
	}

	asset := uploadAsset{
		ID:           randomID("asset"),
		OriginalName: header.Filename,
		StoredName:   storedName,
		ContentType:  contentType,
		SizeBytes:    size,
		URL:          "/uploads/" + storedName,
		UploadedAt:   time.Now().UTC(),
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.uploads = append([]uploadAsset{asset}, s.uploads...)
	if err := s.persistLocked(); err != nil {
		return uploadAsset{}, err
	}
	return asset, nil
}

func (s *store) listUploads() []uploadAsset {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]uploadAsset(nil), s.uploads...)
}

func (s *store) getUpload(id string) (uploadAsset, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for _, item := range s.uploads {
		if item.ID == id {
			return item, true
		}
	}
	return uploadAsset{}, false
}

func extensionFromContentType(contentType string) string {
	switch contentType {
	case "video/quicktime":
		return ".mov"
	case "video/mp4":
		return ".mp4"
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	default:
		return ""
	}
}

func randomID(prefix string) string {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("%s_%d", prefix, time.Now().UnixNano())
	}
	return prefix + "_" + hex.EncodeToString(buf)
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("failed to encode response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}
