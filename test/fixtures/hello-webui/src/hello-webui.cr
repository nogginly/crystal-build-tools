require "baked_file_system"

class Storage
  BakedFileSystem.load("../webui/dist", __DIR__)
end

# Verify the baked file is accessible
file = Storage.get("/index.html")
puts "hello from crystal-build-tools webui test (baked #{file.size} bytes)"
exit 0
