package controller

import (
	"encoding/json"
	"sync"
	"time"
)

const ORDSpecVersion = "1.16"

type ORDDocument struct {
	OpenResourceDiscovery string              `json:"openResourceDiscovery"`
	DescribedSystemType   string              `json:"describedSystemType,omitempty"`
	DescribedSystemVersion string             `json:"describedSystemVersion,omitempty"`
	DescribedSystemInstance string            `json:"describedSystemInstance,omitempty"`
	PolicyLevels          []PolicyLevel       `json:"policyLevel,omitempty"`
	Vendors               []Vendor            `json:"vendors,omitempty"`
	Products              []ProductEntry      `json:"products,omitempty"`
	Packages              []PackageEntry      `json:"packages,omitempty"`
	APIResources          []APIResourceEntry  `json:"apiResources,omitempty"`
	ConsumptionBundles    []ConsumptionBundle `json:"consumptionBundles,omitempty"`
}

type Vendor struct {
	OrdID string `json:"ordId"`
	Title string `json:"title"`
}

type ProductEntry struct {
	OrdID          string   `json:"ordId"`
	Title          string   `json:"title"`
	ShortDescription string `json:"shortDescription,omitempty"`
	Vendor         string   `json:"vendor"`
	PartOfProducts []string `json:"partOfProducts,omitempty"`
	Labels         map[string]string `json:"labels,omitempty"`
}

type PackageEntry struct {
	OrdID          string            `json:"ordId"`
	Title          string            `json:"title"`
	ShortDescription string          `json:"shortDescription,omitempty"`
	Vendor         string            `json:"vendor"`
	PartOfProducts []string          `json:"partOfProducts,omitempty"`
	Version        string            `json:"version"`
	Labels         map[string]string `json:"labels,omitempty"`
	PolicyLevels   []string          `json:"policyLevel,omitempty"`
	LicenseType    string            `json:"licenseType,omitempty"`
	SupportInfo    string            `json:"supportInfo,omitempty"`
	PartOfGroups   []string          `json:"partOfGroups,omitempty"`
}

type APIResourceEntry struct {
	OrdID              string            `json:"ordId"`
	Title              string            `json:"title"`
	ShortDescription   string            `json:"shortDescription,omitempty"`
	APIProtocol        string            `json:"apiProtocol"`
	PartOfPackage      string            `json:"partOfPackage"`
	PartOfConsumptionBundle string        `json:"partOfConsumptionBundle,omitempty"`
	Visibility         string            `json:"visibility"`
	ReleaseStatus      string            `json:"releaseStatus"`
	Labels             map[string]string `json:"labels,omitempty"`
	DefaultConsumptionBundle string       `json:"defaultConsumptionBundle,omitempty"`
	ResourceDefinitions []ResourceDef     `json:"resourceDefinitions,omitempty"`
	PartOfGroups       []string          `json:"partOfGroups,omitempty"`
}

type ResourceDef struct {
	Type      string `json:"type"`
	MediaType string `json:"mediaType"`
	URL       string `json:"url"`
}

type ConsumptionBundle struct {
	OrdID                      string                       `json:"ordId"`
	Title                      string                       `json:"title"`
	ShortDescription           string                       `json:"shortDescription,omitempty"`
	Visibility                 string                       `json:"visibility"`
	CredentialExchangeStrategies []CredentialExchangeStrategy `json:"credentialExchangeStrategies,omitempty"`
}

type CredentialExchangeStrategy struct {
	Type        string `json:"type"`
	CustomType  string `json:"customType,omitempty"`
	CustomDescription string `json:"customDescription,omitempty"`
	CallbackURL string `json:"callbackUrl,omitempty"`
}

type PolicyLevel struct {
	OrdID               string `json:"ordId"`
	Title               string `json:"title"`
	ShortDescription    string `json:"shortDescription,omitempty"`
}

type ORDWriter struct {
	mu  sync.RWMutex
	doc *ORDDocument
}

func (w *ORDWriter) GetORDDocument() (*ORDDocument, error) {
	w.mu.RLock()
	defer w.mu.RUnlock()
	if w.doc == nil {
		empty := &ORDDocument{
			OpenResourceDiscovery: ORDSpecVersion,
			Vendors:              []Vendor{},
			Products:             []ProductEntry{},
			Packages:             []PackageEntry{},
			APIResources:         []APIResourceEntry{},
		}
		return empty, nil
	}
	return w.doc, nil
}

func (w *ORDWriter) SetORDDocument(doc *ORDDocument) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.doc = doc
}

func (w *ORDWriter) GetJSON() ([]byte, error) {
	doc, err := w.GetORDDocument()
	if err != nil {
		return nil, err
	}
	return json.MarshalIndent(doc, "", "  ")
}

func timestamp() string {
	return time.Now().UTC().Format(time.RFC3339)
}