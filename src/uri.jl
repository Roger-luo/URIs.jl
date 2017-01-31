# URI
immutable Offset
    off::UInt16
    len::UInt16
end
Offset() = Offset(0, 0)
Base.getindex(A::Vector{UInt8}, o::Offset) = String(A[o.off:(o.off + o.len - 1)])
Base.isempty(o::Offset) = o.off == 0x0000 && o.len == 0x0000
==(a::Offset, b::Offset) = a.off == b.off && a.len == b.len

immutable URI
    data::Vector{UInt8}
    offsets::NTuple{7, Offset}
end

const URL = URI

function URI(hostname::String, path::String="";
            scheme::String="http", userinfo::String="",
            port::Union{Integer,String}="", query::Union{String,Dict{String,String}}="",
            fragment::String="", isconnect::Bool=false)
    # hostname might be full url
    
    io = IOBuffer()
    print(io, scheme, userinfo, hostname, string(port), path, isa(query, Dict) ? escape(query) : query, fragment)
    return Base.parse(URI, String(take!(io)); isconnect=isconnect)
end

Base.parse(::Type{URI}, str::String; isconnect::Bool=false) = http_parser_parse_url(Vector{UInt8}(str), 1, sizeof(str), isconnect)

==(a::URI,b::URI) = scheme(a)   == scheme(b)    &&
                    hostname(a) == hostname(b)  &&
                    path(a)     == path(b)      &&
                    query(a)    == query(b)     &&
                    fragment(a) == fragment(b)  &&
                    userinfo(a) == userinfo(b)  &&
                    ((!hasport(a) || !hasport(b)) || (port(a) == port(b)))

# accessors
for uf in instances(HTTP.http_parser_url_fields)
    uf == UF_MAX && break
        nm = lowercase(string(uf)[4:end])
    has = Symbol(string("has", nm))
    @eval $has(uri::URI) = uri.offsets[Int($uf)].len > 0
    uf == UF_PORT && continue
    @eval $(Symbol(nm))(uri::URI) = uri.data[uri.offsets[Int($uf)]]
end

# special def for port
function port(uri::URI)
    if hasport(uri)
        return uri.data[uri.offsets[Int(UF_PORT)]]
    else
        sch = scheme(uri)
        return sch == "http" ? "80" : sch == "https" ? "443" : ""
    end
    return ""
end

resource(uri::URI) = path(uri) * (isempty(query(uri)) ? "" : "?$(query(uri))")
host(uri::URI) = hostname(uri) * (isempty(port(uri)) ? "" : ":$(port(uri))")

Base.show(io::IO, uri::URI) = print(io, "HTTP.URI(\"", uri, "\")")

Base.print(io::IO, u::URI) = print(io, scheme(u), userinfo(u), hostname(u), port(u), path(u), query(u), fragment(u))
function Base.print(io::IO, sch::String, userinfo::String, hostname::String, port::String, path::String, query::String, fragment::String)
    if sch in uses_authority
        print(io, sch, "://")
        !isempty(userinfo) && print(io, userinfo, "@")
        print(io, ':' in hostname ? "[$hostname]" : hostname)
        print(io, ((sch == "http" && port == "80") ||
                   (sch == "https" && port == "443") || isempty(port)) ? "" : ":$port")
    else
        print(io, sch, ":")
    end
    print(io, path, isempty(query) ? "" : "?$query", isempty(fragment) ? "" : "#$fragment")
end

# Validate known URI formats
const uses_authority = ["hdfs", "ftp", "http", "gopher", "nntp", "telnet", "imap", "wais", "file", "mms", "https", "shttp", "snews", "prospero", "rtsp", "rtspu", "rsync", "svn", "svn+ssh", "sftp" ,"nfs", "git", "git+ssh", "ldap", "s3"]
const uses_params = ["ftp", "hdl", "prospero", "http", "imap", "https", "shttp", "rtsp", "rtspu", "sip", "sips", "mms", "sftp", "tel"]
const non_hierarchical = ["gopher", "hdl", "mailto", "news", "telnet", "wais", "imap", "snews", "sip", "sips"]
const uses_query = ["http", "wais", "imap", "https", "shttp", "mms", "gopher", "rtsp", "rtspu", "sip", "sips", "ldap"]
const uses_fragment = ["hdfs", "ftp", "hdl", "http", "gopher", "news", "nntp", "wais", "https", "shttp", "snews", "file", "prospero"]

"checks if a `HTTP.URI` is valid"
function Base.isvalid(uri::URI)
    sch = scheme(uri)
    isempty(sch) && throw(ArgumentError("can not validate relative URI"))
    if ((sch in non_hierarchical) && (search(path(uri), '/') > 1)) ||       # path hierarchy not allowed
       (!(sch in uses_query) && !isempty(query(uri))) ||                    # query component not allowed
       (!(sch in uses_fragment) && !isempty(fragment(uri))) ||              # fragment identifier component not allowed
       (!(sch in uses_authority) && (!isempty(hostname(uri)) || ("" != port(uri)) || !isempty(userinfo(uri)))) # authority component not allowed
        return false
    end
    return true
end

lower(c::UInt8) = c | 0x20
const bHOSTCHARS = Set{UInt8}([UInt8('.'), UInt8('-'), UInt8('_'), UInt8('~')])
ishostchar(c::UInt8) = (UInt8('a') <= lower(c) <= UInt8('z')) || UInt8('0') <= c <= UInt8('9') || c in bHOSTCHARS

hexstring(x) = string('%', uppercase(hex(x,2)))

"percent-encode a uri/url string"
function escape(str)
    out = IOBuffer()
    for c in Vector{UInt8}(str)
        write(out, !ishostchar(c) ? hexstring(Int(c)) : c)
    end
    return String(take!(out))
end

function escape(d::Dict)
    io = IOBuffer()
    len = length(d)
    for (i, (k,v)) in enumerate(d)
        write(io, escape(k), "=", escape(v))
        i == len || write(io, "&")
    end
    return String(take!(io))
end

"unescape a percent-encoded uri/url"
function unescape(str)
    out = IOBuffer()
    i = 1
    while !done(str, i)
        c, i = next(str, i)
        if c == '%'
            c1, i = next(str, i)
            c, i = next(str, i)
            write(out, Base.parse(UInt8, string(c1, c), 16))
        else
            write(out, c)
        end
    end
    return String(take!(out))
end

"""
Splits the path into components and parameters
See: http://tools.ietf.org/html/rfc3986#section-3.3
"""
function splitpath(uri::URI, starting=2)
    elems = String[]
    p = path(uri)
    len = length(p)
    len > 1 || return elems
    start_ind = i = starting # p[1] == '/'
    while true
        c = p[i]
        if c == '/'
            push!(elems, p[start_ind:i-1])
            start_ind = i + 1
        elseif i == len
            push!(elems, p[start_ind:i])
        end
        i += 1
        (i > len || c in ('?', '#')) && break
    end
    return elems
end

# url parsing
function parseurlchar(s, ch::Char, strict::Bool)
    (ch == ' ' || ch == '\r' || ch == '\n') && return s_dead
    strict && (ch == '\t' || ch == '\f') && return s_dead

    if s == s_req_spaces_before_url
        (ch == '/' || ch == '*') && return s_req_path
        isalpha(ch) && return s_req_schema
    elseif s == s_req_schema
        isalphanum(ch) && return s
        ch == ':' && return s_req_schema_slash
    elseif s == s_req_schema_slash
        ch == '/' && return s_req_schema_slash_slash
        isurlchar(ch) && return s_req_path
    elseif s == s_req_schema_slash_slash
        ch == '/' && return s_req_server_start
        isurlchar(ch) && return s_req_path
    elseif s == s_req_server_with_at
        ch == '@' && return s_dead
        ch == '/' && return s_req_path
        ch == '?' && return s_req_query_string_start
        (isuserinfochar(ch) || ch == '[' || ch == ']') && return s_req_server
    elseif s == s_req_server_start || s == s_req_server
        ch == '/' && return s_req_path
        ch == '?' && return s_req_query_string_start
        ch == '@' && return s_req_server_with_at
        (isuserinfochar(ch) || ch == '[' || ch == ']') && return s_req_server
    elseif s == s_req_path
        (isurlchar(ch) || ch == '@') && return s
        ch == '?' && return s_req_query_string_start
        ch == '#' && return s_req_fragment_start
    elseif s == s_req_query_string_start || s == s_req_query_string
        isurlchar(ch) && return s_req_query_string
        ch == '?' && return s_req_query_string
        ch == '#' && return s_req_fragment_start
    elseif s == s_req_fragment_start
        isurlchar(ch) && return s_req_fragment
        ch == '?' && return s_req_fragment
        ch == '#' && return s
    elseif s == s_req_fragment
        isurlchar(ch) && return s
        (ch == '?' || ch == '#') && return s
    end
    #= We should never fall out of the switch above unless there's an error =#
    return s_dead;
end

function http_parse_host_char(s::http_host_state, ch)
    if s == s_http_userinfo || s == s_http_userinfo_start
        ch == '@' && return s_http_host_start
        isuserinfochar(ch) && return s_http_userinfo
    elseif s == s_http_host_start
        ch == '[' && return s_http_host_v6_start
        ishostchar(ch) && return s_http_host
    elseif s == s_http_host
        ishostchar(ch) && return s_http_host
        ch == ':' && return s_http_host_port_start
    elseif s == s_http_host_v6_end
        ch == ':' && return s_http_host_port_start
    elseif s == s_http_host_v6
        ch == ']' && return s_http_host_v6_end
        (ishex(ch) || ch == ':' || ch == '.') && return s_http_host_v6
        s == s_http_host_v6 && ch == '%' && return s_http_host_v6_zone_start
    elseif s == s_http_host_v6_start
        (ishex(ch) || ch == ':' || ch == '.') && return s_http_host_v6
        s == s_http_host_v6 && ch == '%' && return s_http_host_v6_zone_start
    elseif s == s_http_host_v6_zone
        ch == ']' && return s_http_host_v6_end
        (isalphanum(ch) || ch == '%' || ch == '.' || ch == '-' || ch == '_' || ch == '~') && return s_http_host_v6_zone
    elseif s == s_http_host_v6_zone_start
        (isalphanum(ch) || ch == '%' || ch == '.' || ch == '-' || ch == '_' || ch == '~') && return s_http_host_v6_zone
    elseif s == s_http_host_port || s == s_http_host_port_start
        isnum(ch) && return s_http_host_port
    end
    return s_http_host_dead
end

function http_parse_host(buf, host::Offset, foundat)
    portoff = portlen = uioff = uilen = UInt16(0)
    off = len = UInt16(0)
    s = ifelse(foundat, s_http_userinfo_start, s_http_host_start)

    for i = host.off:(host.off + host.len - 1)
        p = Char(buf[i])
        new_s = http_parse_host_char(s, p)
        new_s == s_http_host_dead && throw(ParsingError("encountered invalid host character: \n$(String(buf))\n$(lpad("", i-1, "-"))^"))
        if new_s == s_http_host
            if s != s_http_host
                off = i
            end
            len += 1

        elseif new_s == s_http_host_v6
            if s != s_http_host_v6
                off = i
            end
            len += 1

        elseif new_s == s_http_host_v6_zone_start || new_s == s_http_host_v6_zone
            len += 1

        elseif new_s == s_http_host_port
            if s != s_http_host_port
                portoff = i
                portlen = 0
            end
            portlen += 1

        elseif new_s == s_http_userinfo
            if s != s_http_userinfo
                uioff = i
                uilen = 0
            end
            uilen += 1
        end
        s = new_s
    end
    if s in (s_http_host_start, s_http_host_v6_start, s_http_host_v6, s_http_host_v6_zone_start,
             s_http_host_v6_zone, s_http_host_port_start, s_http_userinfo, s_http_userinfo_start)
        throw(ParsingError("ended in unexpected parsing state: $s"))
    end
    # (host, port, userinfo)
    return Offset(off, len), Offset(portoff, portlen), Offset(uioff, uilen)
end

function http_parser_parse_url(buf, startind=1, buflen=length(buf), isconnect::Bool=false)
    s = ifelse(isconnect, s_req_server_start, s_req_spaces_before_url)
    old_uf = UF_MAX
    off = len = 0
    foundat = false
    offsets = Dict{http_parser_url_fields, Offset}()
    for i = startind:(startind + buflen - 1)
        p = Char(buf[i])
        olds = s
        s = parseurlchar(s, p, false)
        if s == s_dead
            throw(ParsingError("encountered invalid url character for parsing state = $(ParsingStateCode(olds)): \n$(String(buf))\n$(lpad("", i-1, "-"))^"))
        elseif s in (s_req_schema_slash, s_req_schema_slash_slash, s_req_server_start, s_req_query_string_start, s_req_fragment_start)
            continue
        elseif s == s_req_schema
            uf = UF_SCHEME
        elseif s == s_req_server_with_at
            foundat = true
            uf = UF_HOSTNAME
        elseif s == s_req_server
            uf = UF_HOSTNAME
        elseif s == s_req_path
            uf = UF_PATH
        elseif s == s_req_query_string
            uf = UF_QUERY
        elseif s == s_req_fragment
            uf = UF_FRAGMENT
        else
            throw(ParsingError("ended in unexpected parsing state: $s"))
        end
        if uf == old_uf
            len += 1
            continue
        end
        if old_uf != UF_MAX
            offsets[old_uf] = Offset(off, len)
        end
        off = i
        len = 1
        old_uf = uf
    end
    offsets[old_uf] = Offset(off, len)
    if haskey(offsets, UF_SCHEME) && (!haskey(offsets, UF_HOSTNAME) && !haskey(offsets, UF_PATH))
        throw(ParsingError("URI must include host with scheme"))
    end
    if haskey(offsets, UF_HOSTNAME)
        host, port, userinfo = http_parse_host(buf, offsets[UF_HOSTNAME], foundat)
        offsets[UF_HOSTNAME] = host
        offsets[UF_PORT] = port
        if !isempty(userinfo)
            offsets[UF_USERINFO] = userinfo
        end
    end
    # CONNECT requests can only contain "hostname:port"
    if isconnect
        (haskey(offsets, UF_HOSTNAME) && haskey(offsets, UF_PORT)) || throw(ParsingError("connect requests must contain both hostname and port"))
        length(offsets) > 2 && throw(ParsingError("connect requests can only contain hostname:port values"))
    end
    return URI(buf, ntuple(x->Base.get(offsets, http_parser_url_fields(x), Offset()), Int(UF_MAX) - 1))
end
