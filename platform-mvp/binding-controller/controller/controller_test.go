package controller

import (
	"testing"
)

func TestGVKConstants(t *testing.T) {
	if RegionalBucketRequestGVK.Group != "platform.example.com" {
		t.Errorf("unexpected group: %s", RegionalBucketRequestGVK.Group)
	}
	if CephObjectStoreUserGVK.Group != "ceph.rook.io" {
		t.Errorf("unexpected group: %s", CephObjectStoreUserGVK.Group)
	}
	if ObjectBucketClaimGVK.Group != "objectbucket.io" {
		t.Errorf("unexpected group: %s", ObjectBucketClaimGVK.Group)
	}
}
