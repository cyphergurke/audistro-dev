package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	legacyrouter "github.com/getkin/kin-openapi/routers/legacy"
)

type config struct {
	Checks []check `json:"checks"`
}

type check struct {
	Name             string            `json:"name"`
	SpecURL          string            `json:"spec_url"`
	URL              string            `json:"url"`
	Method           string            `json:"method"`
	Headers          map[string]string `json:"headers,omitempty"`
	Body             string            `json:"body,omitempty"`
	ExpectedStatus   int               `json:"expected_status"`
	CaptureBodyPath  string            `json:"capture_body_path,omitempty"`
	SkipBodyValidate bool              `json:"skip_body_validate,omitempty"`
}

type specCacheEntry struct {
	router routers.Router
}

func main() {
	var configPath string
	var timeout time.Duration
	flag.StringVar(&configPath, "config", "", "path to JSON config")
	flag.DurationVar(&timeout, "timeout", 8*time.Second, "per-request timeout")
	flag.Parse()

	if strings.TrimSpace(configPath) == "" {
		fatalf("missing -config")
	}

	cfg, err := loadConfig(configPath)
	if err != nil {
		fatalf("load config: %v", err)
	}
	if len(cfg.Checks) == 0 {
		fatalf("config contains no checks")
	}

	client := &http.Client{Timeout: timeout}
	cache := map[string]specCacheEntry{}

	for _, item := range cfg.Checks {
		if err := runCheck(client, cache, item); err != nil {
			fatalf("%s: %v", item.Name, err)
		}
		fmt.Printf("[openapi-conformance] PASS: %s\n", item.Name)
	}
}

func loadConfig(path string) (config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return config{}, err
	}
	var cfg config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func runCheck(client *http.Client, cache map[string]specCacheEntry, item check) error {
	if item.Method == "" {
		return errors.New("method is required")
	}
	if item.URL == "" {
		return errors.New("url is required")
	}
	if item.SpecURL == "" {
		return errors.New("spec_url is required")
	}
	if item.ExpectedStatus == 0 {
		return errors.New("expected_status is required")
	}

	entry, ok := cache[item.SpecURL]
	if !ok {
		loaded, err := loadSpec(client, item.SpecURL)
		if err != nil {
			return fmt.Errorf("load spec %s: %w", item.SpecURL, err)
		}
		entry = loaded
		cache[item.SpecURL] = entry
	}

	var body io.Reader
	if item.Body != "" {
		body = bytes.NewBufferString(item.Body)
	}
	req, err := http.NewRequest(strings.ToUpper(item.Method), item.URL, body)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	for key, value := range item.Headers {
		req.Header.Set(key, value)
	}

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("execute request: %w", err)
	}
	defer resp.Body.Close()

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response body: %w", err)
	}
	if item.CaptureBodyPath != "" {
		if err := os.WriteFile(item.CaptureBodyPath, bodyBytes, 0o600); err != nil {
			return fmt.Errorf("capture response body: %w", err)
		}
	}

	if resp.StatusCode != item.ExpectedStatus {
		return fmt.Errorf("expected status %d, got %d: %s", item.ExpectedStatus, resp.StatusCode, strings.TrimSpace(string(bodyBytes)))
	}

	route, pathParams, err := entry.router.FindRoute(req)
	if err != nil {
		return fmt.Errorf("find route in spec: %w", err)
	}
	if route == nil || route.Operation == nil {
		return errors.New("route missing from spec")
	}

	if !statusDocumented(route.Operation, resp.StatusCode) {
		return fmt.Errorf("status %d is not documented in spec", resp.StatusCode)
	}

	if item.SkipBodyValidate {
		return nil
	}

	contentType := strings.ToLower(strings.TrimSpace(strings.Split(resp.Header.Get("Content-Type"), ";")[0]))
	if !strings.Contains(contentType, "json") {
		return nil
	}

	validationInput := &openapi3filter.ResponseValidationInput{
		RequestValidationInput: &openapi3filter.RequestValidationInput{
			Request:    req,
			PathParams: pathParams,
			Route:      route,
			Options: &openapi3filter.Options{
				AuthenticationFunc: func(context.Context, *openapi3filter.AuthenticationInput) error { return nil },
			},
		},
		Status: resp.StatusCode,
		Header: resp.Header.Clone(),
	}
	validationInput.SetBodyBytes(bodyBytes)

	if err := openapi3filter.ValidateResponse(context.Background(), validationInput); err != nil {
		return fmt.Errorf("response does not conform to spec: %w; body=%s", err, strings.TrimSpace(string(bodyBytes)))
	}
	return nil
}

func loadSpec(client *http.Client, specURL string) (specCacheEntry, error) {
	resp, err := client.Get(specURL)
	if err != nil {
		return specCacheEntry{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return specCacheEntry{}, fmt.Errorf("unexpected status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return specCacheEntry{}, err
	}
	loader := openapi3.NewLoader()
	spec, err := loader.LoadFromData(data)
	if err != nil {
		return specCacheEntry{}, err
	}
	if err := spec.Validate(loader.Context); err != nil {
		return specCacheEntry{}, err
	}
	router, err := legacyrouter.NewRouter(spec)
	if err != nil {
		return specCacheEntry{}, err
	}
	return specCacheEntry{router: router}, nil
}

func statusDocumented(op *openapi3.Operation, status int) bool {
	if op == nil || op.Responses == nil {
		return false
	}
	if op.Responses.Status(status) != nil {
		return true
	}
	return op.Responses.Default() != nil
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[openapi-conformance] FAIL: "+format+"\n", args...)
	os.Exit(1)
}
