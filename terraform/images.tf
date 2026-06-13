# Download the Image Factory ISO to each Proxmox host's ISO storage (via the PVE API —
# no SSH needed). Mirrors the manual `download-url` API calls from Phase 0.
resource "proxmox_download_file" "talos_iso" {
  # Fresh build downloads the ISO to each host. In adopt mode (bootstrap_cluster=false) the ISOs
  # already exist and proxmox_download_file has no import support, so we simply don't manage them.
  for_each = var.bootstrap_cluster ? toset(local.proxmox_hosts) : toset([])

  node_name    = each.value
  datastore_id = var.image_datastore
  content_type = "iso"
  file_name    = local.iso_file_name
  url          = local.iso_url
  # Take ownership of a pre-existing ISO (e.g. left by a prior/manual build) instead of erroring —
  # makes a fresh `apply` idempotent when the schematic ISO is already on the datastore.
  overwrite            = true
  overwrite_unmanaged  = true
}
