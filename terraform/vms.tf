# The 6 Talos VMs. Matches the manual `qm`/PVE-API creation in Phase 1, with the FINAL
# (post-incident) CPU/RAM sizes baked in from locals.nodes.
resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.nodes

  node_name = each.value.host
  vm_id     = each.value.vmid
  name      = "talos-${each.key}"
  tags      = ["kubeshowcase", "talos"] # matches the original `qm` tags (no per-role tag)

  # Talos VMs are not "started by the agent" but we enable the QEMU guest agent (baked into
  # the factory schematic) so Terraform can read the maintenance-mode DHCP IP for config apply.
  agent {
    enabled = true
  }
  stop_on_destroy = true

  cpu {
    cores = each.value.cores
    type  = "host" # pass through host CPU flags
  }
  memory {
    dedicated = each.value.memory
  }

  machine = "q35"
  bios    = "seabios"

  operating_system {
    type = "l26"
  }

  scsi_hardware = "virtio-scsi-pci"

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk
    iothread     = false
  }

  cdrom {
    file_id   = "${var.image_datastore}:iso/${local.iso_file_name}"
    interface = "ide2" # matches the original `qm` creation (ide2), so adopting existing VMs is drift-free
  }

  network_device {
    bridge = var.proxmox_bridge
    model  = "virtio"
  }

  # Boot from disk first (once installed), fall back to the ISO (maintenance mode on first boot).
  boot_order = ["scsi0", "ide2"]

  # The ISO must exist on this host before the VM can reference it.
  depends_on = [proxmox_download_file.talos_iso]

  lifecycle {
    # The Talos installer rewrites the disk; don't let Proxmox-side disk drift trigger replacement.
    ignore_changes = [disk[0].file_format]
  }
}
