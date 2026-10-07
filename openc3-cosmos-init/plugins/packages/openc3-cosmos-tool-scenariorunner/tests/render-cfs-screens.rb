# Read-only fixture generation from the existing CFS plugin, not a deployment.
require 'erb'
require 'fileutils'
$LOAD_PATH.unshift('/cfs/targets/CFS/lib')
target_name = 'CFS-1_QEMU'
%w[cfe_es_hk_tlm_screen cfe_evs_hk_tlm_screen].each do |screen|
  definition = ERB.new(File.read("/cfs/targets/CFS/screens/#{screen}.txt")).result(binding)
  File.write("evidence/#{screen}.txt", definition)
  puts "Rendered #{screen}: #{definition.lines.length} lines"
end
