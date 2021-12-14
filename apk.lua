local BinaryReader = require 'binaryreader'
local BinaryWriter = require 'binarywriter'

local class = require 'libs.class'
local lfs = require 'lfs'

local ffi = require 'ffi'
ffi.cdef[[
unsigned long compressBound(unsigned long sourceLen);
int compress2(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen, int level);
int uncompress(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen);
]]
local zlib = ffi.load(ffi.os == "Windows" and "zlib" or "z")

local function compress(txt)
      local n = zlib.compressBound(#txt)
      local buf = ffi.new("uint8_t[?]", n)
      local buflen = ffi.new("unsigned long[1]", n)
      local res = zlib.compress2(buf, buflen, txt, #txt, 9)
      assert(res == 0)
      return ffi.string(buf, buflen[0])
end

local function uncompress(ptr, n)
      local buf = ffi.new("uint8_t[?]", n)
      local buflen = ffi.new("unsigned long[1]", n)
      local res = zlib.uncompress(buf, buflen, ptr, n)
      assert(res == 0)
      return ffi.string(buf, buflen[0])
end

local apk = class('APK')

local endiltle = class('ENDILTLE')
function endiltle:init(br)
      self.zero_bytes = br:read_bytes(8)
end

local packhedr = class('PACKHEDR')
function packhedr:init(br)
      self.header_size = br:read_int64()
      self.u1 = br:read_int32()
      self.u2 = br:read_int32()
      self.u3 = br:read_int32()
      self.u4 = br:read_int32()
      self.bytes = br:read_bytes(16)
end

local packtoc_ = class('PACKTOC_')
function packtoc_:init(br)
      self.section_size = tonumber(br:read_int64())
      local p = br.position
      self.block_size = br:read_int32()
      self.files = br:read_int32()
      self.align = br:read_int32()
      self.u1 = br:read_int32()

      br.position = p + self.section_size
end

local packfsls = class('PACKFSLS')
function packfsls:init(br)
      self.section_size = tonumber(br:read_int64())
      local p = br.position
      self.count = br:read_int32()
      self.block_size = br:read_int32()
      self.align = br:read_int32()
      self.unknown1 = br:read_int32()

      self.items = {}
      for i = 1, self.count do
            table.insert(self.items, {
                  index = br:read_int32(),
                  u1 = br:read_int32(),
                  file_offset = tonumber(br:read_int64()),
                  size = tonumber(br:read_int64()),
                  uarr = br:read_bytes(16),
            })
      end

      br.position = p + self.section_size
end

local packfshd = class('PACKFSHD')
function packfshd:init(br)
      self.section_size = tonumber(br:read_int64())
      local p = br.position
      self.zero = br:read_int32()
      self.block_size = br:read_int32()
      self.count = br:read_int32()
      self.unknown1 = br:read_int32()

      self.u1 = br:read_int32()
      self.u2 = br:read_int32()
      self.u3 = br:read_int32()
      self.u4 = br:read_int32()

      self.items = {}
      for i = 1, self.count do
            table.insert(self.items, {
                  index = br:read_int32(),
                  unknown = br:read_int32(),
                  file_offset = tonumber(br:read_int64()),
                  unpacked_size = tonumber(br:read_int64()),
                  size = tonumber(br:read_int64()),
            })
      end

      br.position = p + self.section_size
end

local genestrt = class('GENESTRT')
function genestrt:init(br)
      self.section_size = tonumber(br:read_int64())
      local p = br.position
      self.count = br:read_int32()
      self.align = br:read_int32()
      self.name_table_offset_size = br:read_int32()
      self.name_table_size = br:read_int32()

      self.names = {}
      for i = 1, self.count do
            local start_position = br:read_int32()
            local prev = br.position
            br.position = p + self.name_table_offset_size + start_position
            table.insert(self.names, br:read_ascii_string())
            br.position = prev
      end
      br.position = p + self.section_size
end

local sections = {
      ENDILTLE = endiltle,
      PACKHEDR = packhedr,
      ['PACKTOC '] = packtoc_,
      PACKFSLS = packfsls,
      PACKFSHD = packfshd,
      GENESTRT = genestrt,
}

function apk:init(filedata, path)
      self.binaryreader = BinaryReader.new(filedata)
      self.sections = {}
      self.path = path
      lfs.mkdir(path)
      local apk_file = self.binaryreader:read_ascii_string(8)
      if apk_file == 'ENDILTLE' then
            self.binaryreader.position = 0
            while not self.binaryreader:is_eof() do
                  local section_name = self.binaryreader:read_ascii_string(8)
                  local section = sections[section_name]
                  if section then
                        self.sections[section_name] = section(self.binaryreader)
                  else
                        break
                  end
            end

            local sectionfs = self.sections['PACKFSLS'] or self.sections['PACKFSHD']
            local names = self.sections['GENESTRT'].names

            --print(#sectionfs.items)
            --print(#names)

            for i, v in ipairs(sectionfs.items) do
                  local name = names[v.index + 1]
                  local type = name:match(".+(%..+)")
                  print('Unpack: ', name)
                  if not type then
                        self.binaryreader.position = v.file_offset
                        local filedata = self.binaryreader:read_bytes_str(v.size)
                        local nested_apk = apk(filedata, self.path .. '/' .. name)
                  else
                        local folder_path = self.path
                        for path in name:gmatch("([%w%d_]+)/") do
                              folder_path = folder_path  .. '/' .. path
                              lfs.mkdir(folder_path)
                        end
                        local file = io.open(self.path .. '/' .. name, 'wb')
                        local size = v.size
                        if size > 0 then
                              local offset = v.file_offset
                              local unpacked_size = v.unpacked_size
                              self.binaryreader.position = offset
                              local new_filedata = uncompress(self.binaryreader:ffi_pointer(), unpacked_size)
                              file:write(new_filedata)
                        end
                        file:close()
                  end
            end
      else

      end
end

return apk