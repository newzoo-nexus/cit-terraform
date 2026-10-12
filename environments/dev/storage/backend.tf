terraform {
  backend "gcs" {
    bucket = "newzoo-nexus-raw-dev-tfstate"
    prefix = "storage"
  }
}
