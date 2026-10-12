terraform {
  backend "gcs" {
    bucket = "newzoo-nexus-raw-test-tfstate"
    prefix = "storage"
  }
}
