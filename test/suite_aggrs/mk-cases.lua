require"math"
local max = math.max
local maxargs = 0

local aggrs = { }
local seen_aggrs = { }


function canon_type(t)
  -- struct types have more than one char
  if #t > 1 then
    return 'struct '..t
  end
  return t
end

function trim(l) return l:gsub("^%s+",""):gsub("%s+$","") end
function mkcase(id,sig)
  local sig = trim(sig)
  local h = { "/* ",id,":",sig," */ " }
  local t = { "" }
  local pos = 0
  local n_nest = 0
  local aggr = { }
  local aggr_sig = { }
  aggr[0] = { }     -- non-sequential [0] collects all non-aggr types
  aggr_sig[0] = ''
  for i = 1, #sig do
    local name = "a"..pos
    local ch   = sig:sub(i,i)

    -- aggregate nest level change?
    if ch == '{' then
      n_nest = n_nest + 1
      aggr[n_nest] = { }
      aggr_sig[n_nest] = ''
    end

    aggr_sig[n_nest] = aggr_sig[n_nest]..ch

    if ch == '}' then
      -- register yet unseen aggregates, key is sig, val is body and name
      if seen_aggrs[aggr_sig[n_nest]] == nil then
        aggrs[#aggrs+1] = aggr_sig[n_nest]
        ch = 'A'..#aggrs
        seen_aggrs[aggr_sig[n_nest]] = { aggr[n_nest], ch }
      end
      ch = seen_aggrs[aggr_sig[n_nest]][2]

      n_nest = n_nest - 1
      aggr_sig[n_nest] = aggr_sig[n_nest]..aggr_sig[n_nest+1]
    end

    if ch ~= '{' and ch ~= '}' then
      aggr[n_nest][#aggr[n_nest]+1] = canon_type(ch)
      aggr[n_nest][#aggr[n_nest]+1] = 'm'..(#aggr[n_nest] >> 1)
    end


    if n_nest == 0 then
      h[#h+1] = canon_type(ch)
      -- struct types (more than one char) need copying via a func
      if #ch > 1 then
        t[#t+1] = 'f_cp'..ch..'(V_a['..pos.."],&"..name..");"
      else
        t[#t+1] = "V_"..ch.."["..pos.."]="..name..";"
      end

      -- is return type or func arg?
      if pos == 0 then
        h[#h+1] = " f"..id.."("
        h[#h+1] = ''
        t[#t] = ''  -- clear; aggr return type handled explicitly
      else
        h[#h+1] = ' '..name
        h[#h+1] = ","
      end

      pos = pos + 1
    end
  end
  maxargs = max(maxargs, pos-1)
  h[#h] = "){"
  if #h[6] == 1 then
    t[#t+1] = "ret_"..h[6].."("..(pos-1)..")}\n"
  else
    t[#t+1] = "ret_a("..(pos-1)..","..h[6]..")}\n"
  end
  return table.concat(h,"")..table.concat(t,"")
end

function mkfuntab(n)
  local s = { "funptr G_funtab[] = {\n"}
  for i = 0, n-1 do
    s[#s+1] = "\t(funptr)&f"..i..",\n"
  end
  s[#s+1] = "};\n"
  return table.concat(s,"")
end

function mksigtab(sigs)
  local s = { "char const * G_sigtab[] = {\n"}
  for k,v in pairs(sigs) do
    s[#s+1] = '\t"'..v..'",\n'
  end
  s[#s+1] = "};\n"
  return table.concat(s,"")
end

function mkall()
  local lineno = 0
  local sigtab = { }
  local cases = ''
  for line in io.lines() do
    local sig = trim(line)
    cases = cases..mkcase(lineno,sig)
    sigtab[#sigtab+1] = sig
    lineno = lineno + 1
  end

  agg_sizes = {}
  agg_sigs  = {}
  agg_names = {}
  for a = 1, #aggrs do
    k = aggrs[a]
	v = seen_aggrs[k]
    st = 'struct '..v[2]

    agg_sizes[#agg_sizes + 1] = 'sizeof('..st..')'
    agg_sigs [#agg_sigs  + 1] = k
    agg_names[#agg_names + 1] = v[2]

    -- struct def
    io.write('/* '..k..' */\n')
    io.write(st..' { ')
    for i = 1, #v[1], 2 do
      io.write(v[1][i]..' '..v[1][i+1]..'; ')
    end
    io.write("};\n")

    -- struct cp and cmp funcs
    s = {
      'void f_cp'..v[2]..'('..st..' *x, const '..st..' *y) { ',
      'int f_cmp'..v[2]..'(const '..st..' *x, const '..st..' *y) { return '
    }
    o = { '=', '==', 'f_cp', 'f_cmp', '; ', ' && '  }
    for t = 1, 2 do
      io.write(s[t])
      b = {}
      for i = 1, #v[1], 2 do
        if string.match(v[1][i], '^struct') then
		  b[#b+1] = o[t+2]..v[1][i]:sub(8)..'(&x->'..v[1][i+1]..', &y->'..v[1][i+1]..')';
		else
          b[#b+1] = 'x->'..v[1][i+1]..' '..o[t]..' y->'..v[1][i+1];
		end
      end
      if #b == 0 then
        b[1] = '1'  -- to handle empty structs
      end
      io.write(table.concat(b,o[t+4]).."; };\n")
    end

    -- convenient dcnewstruct helper funcs
    io.write('static int nfields'..v[2]..' = '..(#v[1]>>1)..';\n')
    io.write('DCstruct* f_newdcst'..v[2]..'(DCstruct* parent) {\n\tDCstruct* st = parent;\n\tif(!st) st = dcNewStruct(nfields'..v[2]..', sizeof('..st..'), 0, 1);\n\t')
    for i = 1, #v[1], 2 do
      if string.match(v[1][i], '^struct') then
	    io.write('dcSubStruct(st, nfields'..v[1][i]:sub(8)..', offsetof('..st..', '..v[1][i+1]..'), sizeof('..v[1][i]..'), 0, DC_TRUE, 1);\n\t')
        io.write("f_newdcst"..v[1][i]:sub(8)..'(st);\n\t')
	  else
        io.write("dcStructField(st, '"..v[1][i].."', offsetof("..st..', '..v[1][i+1]..'), 1);\n\t')
	  end
    end
    io.write("dcCloseStruct(st);\n\treturn st;\n};\n")
  end

  -- make table.concat work
  if #agg_names > 0 then
    table.insert(agg_names, 1, '')
  end

  io.write(cases)
  io.write(mkfuntab(lineno))
  io.write(mksigtab(sigtab))
  io.write('const char* G_agg_sigs[]  = {\n\t"'..table.concat(agg_sigs, '",\n\t"')..'"\n};\n')
  io.write('int G_agg_sizes[] = {\n\t'..table.concat(agg_sizes, ',\n\t')..'\n};\n')
  io.write('funptr G_agg_newdcstfuncs[] = {'..string.sub(table.concat(agg_names, ',\n\t(funptr)&f_newdcst'),2)..'\n};\n')
  io.write('funptr G_agg_cmpfuncs[] = {'..string.sub(table.concat(agg_names, ',\n\t(funptr)&f_cmp'),2)..'\n};\n')
  io.write("int G_maxargs = "..maxargs..";\n")
end

mkall()

