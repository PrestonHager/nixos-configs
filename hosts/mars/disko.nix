# Mars (PowerEdge R410): legacy BIOS only, one PERC 6/i virtual disk.
# GPT with a BIOS boot partition for GRUB; disko adds the disk to
# boot.loader.grub.devices because of the EF02 partition.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/wwn-0x6d4ae520a94a3800154129fa075a156a";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };
        swap = {
          size = "8G";
          content = { type = "swap"; };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
