terraform {
  backend "gcs" {
    bucket = "newzoo-nexus-raw-tfstate"
    prefix = "secrets"
  }
}
