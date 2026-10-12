# Import blocks for bringing existing buckets under Terraform. Add the bucket to
# storage/buckets.yaml first (with `name` if it doesn't follow "newzoo-nexus-raw-test-<key>"),
# then uncomment and adapt. Safe to delete once applied.
#
# import {
#   to = module.storage.google_storage_bucket.bucket["exports"]
#   id = "newzoo-nexus-raw-test/some-legacy-bucket-name"
# }
