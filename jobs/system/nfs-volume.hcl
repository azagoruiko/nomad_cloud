# nfs-volume.hcl
type      = "csi"
id        = "nfs"
name      = "nfs"
plugin_id = "nfs"

capability {
  access_mode     = "multi-node-multi-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.1.10"
  share  = "/i-data/d2526f81/nfs/share"  # именно этот путь из showmount -e
}

mount_options {
  fs_type     = "nfs"
  mount_flags = ["vers=3"]               # или: ["vers=3","nolock"] если не хочешь statd
}
