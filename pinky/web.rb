# frozen_string_literal: true
# The browsing and pruning UI plus a JSON API, as one object with call(request) -> Response.
# HTML is assembled by hand (no ERB under Spinel); every value passes through Markdown.h.
require "json"
require "pinky/http"
require "pinky/markdown"
require "pinky/store"

module Pinky
  class Web
    def initialize(store)
      @store = store
    end

    def call(req)
      segments = req.path.split("/").reject(&:empty?)
      case req.method
      when "GET" then get(req, segments)
      when "POST" then post(req, segments)
      else HTTP::Response.text("method not allowed\n", 405)
      end
    end

    private

    def h(s) = Markdown.h(s)

    def get(req, segments)
      if segments.empty?
        index(req)
      elsif segments[0] == "facts" && segments.size == 2 && segments[1] == "new"
        page("New fact", new_form)
      elsif segments[0] == "facts" && segments.size == 2
        show(segments[1].to_i)
      elsif segments[0] == "facts" && segments.size == 3 && segments[2] == "edit"
        edit(segments[1].to_i)
      elsif segments[0] == "api" && segments[1] == "facts" && segments.size == 2
        api_search(req)
      elsif segments[0] == "api" && segments[1] == "facts" && segments.size == 3
        fact = @store.get(segments[2].to_i)
        fact ? HTTP::Response.json(JSON.generate(fact)) : HTTP::Response.json("{\"error\":\"not found\"}", 404)
      elsif segments[0] == "api" && segments[1] == "projects" && segments.size == 2
        HTTP::Response.json(JSON.generate(@store.projects))
      elsif segments[0] == "style.css"
        HTTP::Response.new(200, CSS, "text/css; charset=utf-8")
      else
        HTTP::Response.not_found
      end
    end

    def post(req, segments)
      form = req.form
      if segments == ["facts"]
        id, created = @store.add(form["body"].to_s, agent: blank(form["agent"]) || "web", project: blank(form["project"]) || "misc",
                                 title: blank(form["title"]), kind: blank(form["kind"]) || "fact", tags: form["tags"].to_s.split(","), source: "web")
        HTTP::Response.redirect("/facts/#{id}#{created ? "" : "?dup=1"}")
      elsif segments[0] == "facts" && segments.size == 2
        id = segments[1].to_i
        fact = @store.update(id, body: blank(form["body"]), title: blank(form["title"]), kind: blank(form["kind"]),
                             tags: form["tags"].to_s.split(","))
        fact ? HTTP::Response.redirect("/facts/#{id}") : HTTP::Response.not_found("no fact ##{id}")
      elsif segments[0] == "facts" && segments.size == 3
        id = segments[1].to_i
        case segments[2]
        when "archive"
          @store.archive(id)
          HTTP::Response.redirect(form["back"].to_s.empty? ? "/" : form["back"].to_s)
        when "restore"
          @store.restore(id)
          HTTP::Response.redirect("/facts/#{id}")
        when "purge"
          @store.delete(id)
          HTTP::Response.redirect("/?archived=1")
        else HTTP::Response.not_found
        end
      elsif segments == ["archive"]
        n = 0
        form["ids"].to_s.split(",").each { |s| n += 1 if @store.archive(s.to_i) }
        HTTP::Response.redirect("/?archived_n=#{n}")
      else
        HTTP::Response.not_found
      end
    rescue ArgumentError => e
      page("Error", "<p class=\"error\">#{h(e.message)}</p><p><a href=\"javascript:history.back()\">Back</a></p>", 400)
    end

    def blank(v)
      s = v.to_s.strip
      s.empty? ? nil : s
    end

    def index(req)
      q = req.query["q"].to_s
      project = blank(req.query["project"])
      agent = blank(req.query["agent"])
      kind = blank(req.query["kind"])
      tag = blank(req.query["tag"])
      archived = req.query["archived"].to_s == "1"
      mode = blank(req.query["mode"]) || "hybrid"
      facts = if q.strip.empty?
        @store.list(project: project, agent: agent, kind: kind, tag: tag, archived: archived, limit: 200)
      else
        @store.search(q, mode: mode, project: project, agent: agent, kind: kind, tag: tag, limit: 50)
      end
      body = +""
      body << "<form class=\"search\" method=\"get\" action=\"/\">"
      body << "<input type=\"search\" name=\"q\" value=\"#{h(q)}\" placeholder=\"search facts (hybrid full-text + semantic)\" autofocus>"
      body << select("project", [""] + @store.projects.map { |r| r["project"].to_s }, project.to_s, "all projects")
      body << select("kind", [""] + Store::KINDS, kind.to_s, "all kinds")
      body << select("mode", ["hybrid", "fts", "vector"], mode, nil)
      body << hidden("archived", "1") if archived
      body << hidden("agent", agent) if agent
      body << hidden("tag", tag) if tag
      body << "<button>Search</button></form>"
      filters = []
      filters << "agent <b>#{h(agent)}</b>" if agent
      filters << "tag <b>#{h(tag)}</b>" if tag
      body << "<p class=\"muted\">Filtering by #{filters.join(", ")}. <a href=\"/\">clear</a></p>" unless filters.empty?
      body << "<p class=\"muted\">#{archived ? "Archived facts" : "#{facts.size} #{q.strip.empty? ? "facts" : "matches"}"}. "
      body << (archived ? "<a href=\"/\">active</a>" : "<a href=\"/?archived=1\">archived</a>") << " · <a href=\"/facts/new\">new fact</a></p>"
      if facts.empty?
        body << "<p>Nothing here.</p>"
      else
        body << "<form method=\"post\" action=\"/archive\" id=\"bulk\">"
        body << "<table><thead><tr><th></th><th>id</th><th>kind</th><th>title</th><th>project</th><th>tags</th><th>updated</th>#{q.strip.empty? ? "" : "<th>via</th>"}</tr></thead><tbody>"
        facts.each do |f|
          id = f["id"].to_s
          body << "<tr><td>#{archived ? "" : "<input type=\"checkbox\" name=\"id\" value=\"#{id}\" onchange=\"sync()\">"}</td>"
          body << "<td><a href=\"/facts/#{id}\">##{id}</a></td><td><span class=\"kind #{h(f["kind"])}\">#{h(f["kind"])}</span></td>"
          body << "<td><a href=\"/facts/#{id}\">#{h(f["title"])}</a></td>"
          body << "<td><a href=\"/?project=#{HTTP.escape(f["project"].to_s)}\">#{h(f["project"])}</a></td>"
          body << "<td>" << f["tags"].to_s.split(" ").map { |t| "<a class=\"tag\" href=\"/?tag=#{HTTP.escape(t)}\">#{h(t)}</a>" }.join(" ") << "</td>"
          body << "<td class=\"muted\">#{h(f["updated_at"].to_s[0, 10])}</td>"
          body << "<td class=\"muted\">#{h(f["via"])}</td>" unless q.strip.empty?
          body << "</tr>"
        end
        body << "</tbody></table>"
        body << "<input type=\"hidden\" name=\"ids\" id=\"ids\"><button id=\"bulkbtn\" disabled>Archive selected</button></form>" unless archived
        body << "<script>function sync(){var c=document.querySelectorAll('input[name=id]:checked');var v=[];c.forEach(function(x){v.push(x.value)});document.getElementById('ids').value=v.join(',');document.getElementById('bulkbtn').disabled=v.length==0}</script>"
      end
      page(q.strip.empty? ? "Facts" : "Search: #{q}", body)
    end

    def show(id)
      f = @store.get(id)
      return HTTP::Response.not_found("no fact ##{id}") unless f
      body = +""
      body << "<p class=\"muted\"><a href=\"/\">&larr; all facts</a></p>"
      body << "<h1>#{h(f["title"])}</h1>"
      body << "<p class=\"meta\"><span class=\"kind #{h(f["kind"])}\">#{h(f["kind"])}</span> · project <a href=\"/?project=#{HTTP.escape(f["project"].to_s)}\">#{h(f["project"])}</a>"
      body << " · agent <a href=\"/?agent=#{HTTP.escape(f["agent"].to_s)}\">#{h(f["agent"])}</a>"
      body << " · " << f["tags"].to_s.split(" ").map { |t| "<a class=\"tag\" href=\"/?tag=#{HTTP.escape(t)}\">#{h(t)}</a>" }.join(" ") unless f["tags"].to_s.empty?
      body << "<br>created #{h(f["created_at"])} · updated #{h(f["updated_at"])}"
      body << " · <b>archived #{h(f["archived_at"])}</b>" if f["archived_at"]
      body << " · source #{h(f["source"])}" if f["source"]
      body << "</p>"
      body << "<div class=\"fact\">" << Markdown.render(body_without_title(f)) << "</div>"
      body << "<p class=\"actions\">"
      if f["archived_at"]
        body << form_button("/facts/#{id}/restore", "Restore") << form_button("/facts/#{id}/purge", "Delete for good", true)
      else
        body << "<a class=\"button\" href=\"/facts/#{id}/edit\">Edit</a>" << form_button("/facts/#{id}/archive", "Archive")
      end
      body << "</p>"
      page(f["title"].to_s, body)
    end

    # The page already shows the title, so a leading markdown heading that repeats it is dropped.
    def body_without_title(f)
      lines = f["body"].to_s.split("\n")
      lines.shift if !lines.empty? && lines[0].to_s.strip.sub(/\A#+\s*/, "") == f["title"].to_s
      lines.join("\n")
    end

    def edit(id)
      f = @store.get(id)
      return HTTP::Response.not_found("no fact ##{id}") unless f
      page("Edit ##{id}", fact_form("/facts/#{id}", f, "Save"))
    end

    def new_form
      f = { "title" => "", "kind" => "fact", "tags" => "", "body" => "", "project" => "", "agent" => "" }
      fact_form("/facts", f, "Add fact")
    end

    def fact_form(action, f, label)
      body = +""
      body << "<form method=\"post\" action=\"#{action}\" class=\"edit\">"
      body << "<label>Title <input name=\"title\" value=\"#{h(f["title"])}\" placeholder=\"derived from the first line if empty\"></label>"
      body << "<label>Kind " << select("kind", Store::KINDS, f["kind"].to_s, nil) << "</label>"
      body << "<label>Tags <input name=\"tags\" value=\"#{h(f["tags"].to_s.split(" ").join(","))}\" placeholder=\"comma,separated\"></label>"
      if action == "/facts"
        body << "<label>Project <input name=\"project\" value=\"#{h(f["project"])}\" required></label>"
        body << "<label>Agent <input name=\"agent\" value=\"#{h(f["agent"])}\" placeholder=\"web\"></label>"
      end
      body << "<label>Body (markdown)<textarea name=\"body\" rows=\"14\" required>#{h(f["body"])}</textarea></label>"
      body << "<p><button>#{h(label)}</button> <a href=\"#{action == "/facts" ? "/" : action}\">Cancel</a></p></form>"
      body
    end

    def select(name, options, current, blank_label)
      out = +""
      out << "<select name=\"#{name}\">"
      options.each do |o|
        label = o.empty? ? blank_label.to_s : o
        out << "<option value=\"#{h(o)}\"#{o == current ? " selected" : ""}>#{h(label)}</option>"
      end
      out << "</select>"
      out
    end

    def hidden(name, value) = "<input type=\"hidden\" name=\"#{name}\" value=\"#{h(value)}\">"

    def form_button(action, label, danger = false)
      "<form method=\"post\" action=\"#{action}\" class=\"inline\"><button#{danger ? " class=\"danger\"" : ""}>#{h(label)}</button></form>"
    end

    def api_search(req)
      q = req.query["q"].to_s
      project = blank(req.query["project"])
      limit = blank(req.query["limit"]) ? req.query["limit"].to_s.to_i : 20
      rows = if q.strip.empty?
        @store.list(project: project, kind: blank(req.query["kind"]), tag: blank(req.query["tag"]), limit: limit)
      else
        @store.search(q, mode: blank(req.query["mode"]) || "hybrid", project: project, kind: blank(req.query["kind"]), tag: blank(req.query["tag"]), limit: limit)
      end
      HTTP::Response.json(JSON.generate(rows))
    end

    def page(title, body, status = 200)
      html = +""
      html << "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
      html << "<title>#{h(title)} · pinky</title><link rel=\"stylesheet\" href=\"/style.css\"></head><body>"
      html << "<header><a href=\"/\" class=\"brand\">pinky</a> <span class=\"muted\">local knowledge base</span></header><main>"
      html << body
      html << "</main></body></html>"
      HTTP::Response.html(html, status)
    end

    CSS = <<~CSS
      :root { color-scheme: light dark; --muted: #777; --line: #ddd; --bg: #f6f6f4; --fg: #222; --accent: #b5407a; }
      @media (prefers-color-scheme: dark) { :root { --line: #333; --bg: #1c1c1e; --fg: #e8e8e8; --muted: #999; } }
      body { margin: 0; font: 15px/1.45 system-ui, -apple-system, sans-serif; background: var(--bg); color: var(--fg); }
      header { padding: 12px 24px; border-bottom: 1px solid var(--line); }
      .brand { font-weight: 700; color: var(--accent); text-decoration: none; font-size: 18px; }
      main { max-width: 1100px; margin: 0 auto; padding: 16px 24px 48px; }
      a { color: inherit; } a:hover { color: var(--accent); }
      .muted { color: var(--muted); }
      form.search { display: flex; gap: 8px; flex-wrap: wrap; margin: 8px 0 12px; }
      form.search input[type=search] { flex: 1; min-width: 240px; padding: 8px 10px; font-size: 15px; }
      select, button, input { font: inherit; padding: 6px 8px; }
      button { cursor: pointer; } button.danger { color: #b00; }
      a.button { display: inline-block; padding: 6px 10px; border: 1px solid var(--line); border-radius: 4px; text-decoration: none; }
      table { width: 100%; border-collapse: collapse; }
      th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
      th { font-weight: 600; color: var(--muted); font-size: 13px; }
      .kind { font-size: 12px; padding: 1px 6px; border-radius: 3px; background: var(--line); }
      .kind.gotcha { background: #fde2c8; color: #5a2d00; } .kind.decision { background: #d6e4ff; color: #0b2a6b; }
      .tag { font-size: 12px; text-decoration: none; border: 1px solid var(--line); border-radius: 3px; padding: 0 5px; }
      .fact { padding: 12px 16px; border: 1px solid var(--line); border-radius: 6px; background: rgba(127,127,127,.06); }
      .fact pre { overflow-x: auto; padding: 8px; background: rgba(127,127,127,.12); border-radius: 4px; }
      .fact code { font-size: 13px; }
      .actions form.inline { display: inline; margin-left: 8px; }
      form.edit label { display: block; margin: 10px 0; }
      form.edit input, form.edit textarea, form.edit select { width: 100%; box-sizing: border-box; margin-top: 4px; }
      .error { color: #b00; }
    CSS
  end
end
