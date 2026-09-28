package httpapi

import (
	"net/http"
	"runtime"
	"strings"

	"github.com/ukstress/ukstress/api/internal/normalize"
)

// DefaultLexiconCanary are everyday words with one stress each, which every
// complete lexicon holds. A database that answers but lacks them is the wrong
// lexicon, and without this check it fails silently: a deployment restored
// from an old Wiktionary-only import served «цьо́го», «о́дин», «мето́ди» --
// every word it missed took the positional default, readiness said "ready",
// and no response carried a warning.
var DefaultLexiconCanary = []string{"цього", "один", "методи", "ситуації", "наступного", "мислити"}

// handleLive implements GET /health/live. Liveness stays healthy even with
// no active dataset — the process is up, whether or not there is
// currently anything to serve.
func (s *Server) handleLive(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "live"})
}

// handleReady implements GET /health/ready. Readiness fails when
// PostgreSQL is unreachable or no dataset is published. Healthy() and
// ActiveDataset() are checked separately: a connection failure must not
// be masked by a dataset ID cached from before PostgreSQL became
// unreachable.
func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	if !s.repo.Healthy() {
		writeError(w, r, http.StatusServiceUnavailable, "not_ready", "database is unreachable")
		return
	}
	if _, err := s.repo.ActiveDataset(); err != nil {
		writeError(w, r, http.StatusServiceUnavailable, "not_ready", err.Error())
		return
	}
	if missing, err := s.missingCanary(r); err != nil {
		writeError(w, r, http.StatusServiceUnavailable, "not_ready", "lexicon lookup failed")
		return
	} else if len(missing) > 0 {
		writeError(w, r, http.StatusServiceUnavailable, "lexicon_incomplete",
			"the lexicon lacks everyday words ("+strings.Join(missing, ", ")+
				"): it is not the published lexicon, or its datasets are not configured")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// missingCanary returns the canary words the served datasets do not hold.
func (s *Server) missingCanary(r *http.Request) ([]string, error) {
	if len(s.canary) == 0 {
		return nil, nil
	}
	keys := make([]string, len(s.canary))
	for i, word := range s.canary {
		keys[i] = normalize.LookupKey(word)
	}
	signatures, _, _, err := s.repo.BatchSignaturesWithCase(r.Context(), keys)
	if err != nil {
		return nil, err
	}
	missing := make([]string, 0)
	for i, key := range keys {
		if len(signatures[key]) == 0 {
			missing = append(missing, s.canary[i])
		}
	}
	return missing, nil
}

func (s *Server) handleVersion(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"version":    s.version,
		"go_version": runtime.Version(),
	})
}

func (s *Server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	stats := s.repo.PoolStats()
	s.metrics.SetPoolStats(stats.AcquiredConns(), stats.IdleConns(), stats.MaxConns())
	if id, err := s.repo.ActiveDataset(); err == nil {
		s.metrics.SetActiveDataset(id)
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	s.metrics.Render(w)
}
