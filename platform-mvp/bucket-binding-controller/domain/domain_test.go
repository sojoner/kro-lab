package domain

import (
	"strings"
	"testing"
)

func TestBucketName(t *testing.T) {
	r := Request{Name: "media-eu", Tenant: "acme-corp"}
	if got, want := BucketName(r), "acme-corp-media-eu"; got != want {
		t.Fatalf("BucketName = %q, want %q", got, want)
	}
}

func TestCheckBucketName(t *testing.T) {
	cases := []struct {
		name    string
		bucket  string
		wantErr bool
	}{
		{"ok", "acme-corp-media-eu", false},
		{"max length", strings.Repeat("a", 63), false},
		{"too long", strings.Repeat("a", 64), true},
		{"too short", "ab", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := CheckBucketName(c.bucket); (err != nil) != c.wantErr {
				t.Fatalf("CheckBucketName(%q) err = %v, wantErr %v", c.bucket, err, c.wantErr)
			}
		})
	}
}

func TestTenantNamespace(t *testing.T) {
	cases := []struct {
		name   string
		labels map[string]string
		want   string
		wantOK bool
	}{
		{"label wins", map[string]string{LabelTenant: "acme-corp"}, "acme-corp", true},
		{"empty label is missing", map[string]string{LabelTenant: ""}, "", false},
		{"missing label is missing", nil, "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := TenantNamespace(c.labels)
			if got != c.want || ok != c.wantOK {
				t.Fatalf("TenantNamespace = (%q, %v), want (%q, %v)", got, ok, c.want, c.wantOK)
			}
		})
	}
}

func TestMissingTenantStatus(t *testing.T) {
	want := Status{Region: "eu", Phase: PhaseUnschedulable, Message: "missing label platform.example.com/tenant"}
	if got := MissingTenantStatus("eu"); got != want {
		t.Fatalf("MissingTenantStatus = %+v, want %+v", got, want)
	}
}

func TestResolveCluster(t *testing.T) {
	const regionLabel = "platform.example.com/region"
	profile := func(name, region string) Profile {
		return Profile{Name: name, Labels: map[string]string{regionLabel: region}}
	}
	cases := []struct {
		name     string
		region   string
		profiles []Profile
		want     string
		wantOK   bool
	}{
		{"matches by region label, not by name", "eu", []Profile{profile("eu-storage", "eu")}, "eu-storage", true},
		{"ignores other regions", "eu", []Profile{profile("us", "us"), profile("eu-storage", "eu")}, "eu-storage", true},
		{"no profile for the region", "asia", []Profile{profile("eu-storage", "eu")}, "", false},
		{"profile without region label", "eu", []Profile{{Name: "eu-storage"}}, "", false},
		{"no profiles", "eu", nil, "", false},
		{"several matches pick the first by name", "eu", []Profile{profile("eu-b", "eu"), profile("eu-a", "eu")}, "eu-a", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := ResolveCluster(c.region, regionLabel, c.profiles)
			if got != c.want || ok != c.wantOK {
				t.Fatalf("ResolveCluster = (%q, %v), want (%q, %v)", got, ok, c.want, c.wantOK)
			}
		})
	}
}

func TestReadyStatus(t *testing.T) {
	r := Request{Name: "media-eu", Tenant: "acme-corp", Region: "eu"}
	cases := []struct {
		name  string
		claim Claim
		want  Status
	}{
		{
			"bound claim with endpoint is ready",
			Claim{Phase: "Bound", Host: "rgw.svc", Port: "80"},
			Status{Region: "eu", Phase: PhaseReady, BucketName: "acme-corp-media-eu", Endpoint: "http://rgw.svc:80"},
		},
		{
			"bound claim without host is still pending",
			Claim{Phase: "Bound"},
			Status{Region: "eu", Phase: PhasePending, BucketName: "acme-corp-media-eu"},
		},
		{
			"pending claim",
			Claim{Phase: "Pending"},
			Status{Region: "eu", Phase: PhasePending, BucketName: "acme-corp-media-eu"},
		},
		{
			"missing claim",
			Claim{},
			Status{Region: "eu", Phase: PhasePending, BucketName: "acme-corp-media-eu"},
		},
		{
			"host without port",
			Claim{Phase: "Bound", Host: "rgw.svc"},
			Status{Region: "eu", Phase: PhaseReady, BucketName: "acme-corp-media-eu", Endpoint: "http://rgw.svc"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ReadyStatus(r, c.claim); got != c.want {
				t.Fatalf("ReadyStatus = %+v, want %+v", got, c.want)
			}
		})
	}
}

func TestUnschedulableStatus(t *testing.T) {
	got := UnschedulableStatus("asia")
	if got.Phase != PhaseUnschedulable || got.Region != "asia" {
		t.Fatalf("UnschedulableStatus = %+v", got)
	}
	if !strings.Contains(got.Message, "asia") {
		t.Fatalf("message %q does not name the region", got.Message)
	}
}
