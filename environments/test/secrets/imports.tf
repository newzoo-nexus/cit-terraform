# Import blocks for bringing existing secrets under Terraform. Add the secret to
# secrets/secrets.yaml first, then uncomment and adapt. Importing never touches the value.
# Safe to delete once applied.
#
# import {
#   to = module.secrets.google_secret_manager_secret.secret["steam-api-key"]
#   id = "projects/newzoo-nexus-raw-test/secrets/steam-api-key"
# }
