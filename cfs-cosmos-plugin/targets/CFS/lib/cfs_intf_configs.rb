# Transport endpoints are independent of CPU numbers / CCSDS IDs.
def cfs_get_port_num_cmd(target_name)
  case target_name
  when 'CFS-1_BBB', 'CFS-1_QEMU' then '1234'
  else raise ArgumentError, "Unknown cFS target: #{target_name}"
  end
end

def cfs_get_port_num_tlm(target_name)
  case target_name
  when 'CFS-1_BBB' then '1235'
  when 'CFS-1_QEMU' then '1236'
  else raise ArgumentError, "Unknown cFS target: #{target_name}"
  end
end

def cfs_get_port_num_xband(target_name)
  case target_name
  when 'CFS-1_BBB' then '4322'
  when 'CFS-1_QEMU' then '4323'
  else raise ArgumentError, "Unknown cFS target: #{target_name}"
  end
end
