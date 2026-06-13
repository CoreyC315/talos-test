# Download the Image Factory ISO to each Proxmox host's ISO storage (via the PVE API —
# no SSH needed). Mirrors the manual `download-url` API calls from Phase 0.
resource "proxmox_download_file" "talos_iso" {
  for_each = toset(local.proxmox_hosts)

  node_name    = each.value
  datastore_id = var.image_datastore
  content_type = "iso"
  file_name    = local.iso_file_name
  url          = local.iso_url
  # overwrite the existing manual download if checksums differ
  overwrite = false
}
