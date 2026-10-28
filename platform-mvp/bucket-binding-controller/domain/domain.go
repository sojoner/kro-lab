// Package domain holds the pure rules of the bucket service: which cluster
// serves a region, what the S3 bucket is called, and what a claim's state
// means for the request. It imports nothing from Kubernetes; every function
// is deterministic.
package domain

import (
	"fmt"
	"sort"
)

// Label keys that tie a spoke claim back to the hub request that owns it.
const (
	LabelTenant           = "platform.example.com/tenant"
	LabelBucket           = "platform.example.com/bucket"
	LabelRequest          = "platform.example.com/bucket-request"
	LabelRequestNamespace = "platform.example.com/bucket-request-namespace"
)

// S3 bucket naming limits (3-63 characters).
const (
	minBucketNameLen = 3
	maxBucketNameLen = 63
)

// ClaimBound is the ObjectBucketClaim phase once the bucket and its
// credentials exist.
const ClaimBound = "Bound"

// Request is one RegionalBucketRequest, reduced to what planning needs.
type Request struct {
	Name       string // hub object name, also the claim name on the spoke
	Namespace  string // hub namespace of the request
	Region     string
	Tenant     string // spoke namespace the claim lives in
	Bucket     string // name of the Bucket that produced this request
	MaxSize    string // quota, Kubernetes quantity
	MaxObjects int
}

// Profile is a hub ClusterProfile reduced to its name and labels.
type Profile struct {
	Name   string
	Labels map[string]string
}

// Claim is what the spoke reports about a request's ObjectBucketClaim.
// The zero value means the claim does not exist yet.
type Claim struct {
	Phase string
	Host  string // BUCKET_HOST of the claim's ConfigMap
	Port  string // BUCKET_PORT of the claim's ConfigMap
}

type Phase string

const (
	PhasePending       Phase = "Pending"
	PhaseReady         Phase = "Ready"
	PhaseUnschedulable Phase = "Unschedulable"
)

// Status is what the hub request reports for its region.
type Status struct {
	Region     string
	Phase      Phase
	BucketName string
	Endpoint   string
	Message    string
}

// BucketName is the S3 bucket name of a request: unique across tenants
// because the tenant is part of it.
func BucketName(r Request) string {
	return fmt.Sprintf("%s-%s", r.Tenant, r.Name)
}

// CheckBucketName rejects names S3 would refuse, so the claim does not sit
// Pending forever.
func CheckBucketName(name string) error {
	if n := len(name); n < minBucketNameLen || n > maxBucketNameLen {
		return fmt.Errorf("bucket name %q is %d characters, want %d-%d", name, n, minBucketNameLen, maxBucketNameLen)
	}
	return nil
}

// TenantNamespace is the spoke namespace for a request: the tenant label,
// or fallback when it is absent or empty.
func TenantNamespace(labels map[string]string, fallback string) string {
	if tenant := labels[LabelTenant]; tenant != "" {
		return tenant
	}
	return fallback
}

// ResolveCluster picks the cluster serving region: the profile whose
// regionLabel equals region. Callers pass only profiles that offer the
// service. With several candidates the first by name wins, so the choice is
// stable.
func ResolveCluster(region, regionLabel string, profiles []Profile) (string, bool) {
	var names []string
	for _, p := range profiles {
		if p.Labels[regionLabel] == region {
			names = append(names, p.Name)
		}
	}
	if len(names) == 0 {
		return "", false
	}
	sort.Strings(names)
	return names[0], true
}

// ReadyStatus is Ready only when the claim is Bound and its endpoint is
// known; anything less is Pending.
func ReadyStatus(r Request, c Claim) Status {
	s := Status{Region: r.Region, Phase: PhasePending, BucketName: BucketName(r)}
	if c.Phase == ClaimBound && c.Host != "" {
		s.Phase = PhaseReady
		s.Endpoint = endpoint(c)
	}
	return s
}

func UnschedulableStatus(region string) Status {
	return Status{
		Region:  region,
		Phase:   PhaseUnschedulable,
		Message: fmt.Sprintf("region %q does not offer object storage", region),
	}
}

func endpoint(c Claim) string {
	if c.Port == "" {
		return "http://" + c.Host
	}
	return fmt.Sprintf("http://%s:%s", c.Host, c.Port)
}
