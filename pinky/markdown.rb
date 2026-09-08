# frozen_string_literal: true
# A small markdown-to-HTML renderer for fact bodies: headings, paragraphs, bullet and numbered lists,
# fenced and inline code, bold, italic, links. Everything is HTML-escaped first; unknown constructs
# render as text. Enough for facts, not a general-purpose parser.
module Pinky
  module Markdown
    def self.h(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\"", "&quot;")
    end

    def self.render(text)
      out = +""
      para = []
      list = nil
      code = nil
      text.to_s.split("\n").each do |raw|
        line = raw.rstrip
        if code
          if line.start_with?("```")
            out << "<pre><code>" << h(code.join("\n")) << "</code></pre>\n"
            code = nil
          else
            code << line
          end
          next
        end
        if line.start_with?("```")
          flush_para(out, para)
          list = close_list(out, list)
          code = []
        elsif line.strip.empty?
          flush_para(out, para)
          list = close_list(out, list)
        elsif line =~ /\A(#{"#"}{1,6})\s+(.*)\z/
          flush_para(out, para)
          list = close_list(out, list)
          level = $1.size
          out << "<h#{level}>" << inline(Regexp.last_match(2).to_s) << "</h#{level}>\n"
        elsif line =~ /\A\s*[-*+]\s+(.*)\z/
          flush_para(out, para)
          list = open_list(out, list, "ul")
          out << "<li>" << inline(Regexp.last_match(1).to_s) << "</li>\n"
        elsif line =~ /\A\s*\d+[.)]\s+(.*)\z/
          flush_para(out, para)
          list = open_list(out, list, "ol")
          out << "<li>" << inline(Regexp.last_match(1).to_s) << "</li>\n"
        else
          list = close_list(out, list)
          para << line.strip
        end
      end
      out << "<pre><code>" << h(code.join("\n")) << "</code></pre>\n" if code
      flush_para(out, para)
      close_list(out, list)
      out
    end

    # Inline code is protected from the other substitutions by rendering it first into placeholders.
    def self.inline(text)
      codes = []
      s = h(text).gsub(/`([^`]+)`/) do
        codes << "<code>#{Regexp.last_match(1)}</code>"
        " #{codes.size - 1} "
      end
      s = s.gsub(/\[([^\]]+)\]\((https?:[^)\s]+)\)/) { "<a href=\"#{Regexp.last_match(2)}\">#{Regexp.last_match(1)}</a>" }
      s = s.gsub(/\*\*([^*]+)\*\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }
      s = s.gsub(/(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])/) { "<em>#{Regexp.last_match(1)}</em>" }
      s = s.gsub(/(?<!\w)_([^_\s][^_]*)_(?!\w)/) { "<em>#{Regexp.last_match(1)}</em>" }
      s.gsub(/ (\d+) /) { codes[Regexp.last_match(1).to_i].to_s }
    end

    def self.flush_para(out, para)
      return if para.empty?
      out << "<p>" << inline(para.join(" ")) << "</p>\n"
      para.clear
      nil
    end

    def self.open_list(out, list, tag)
      return list if list == tag
      close_list(out, list)
      out << "<#{tag}>\n"
      tag
    end

    def self.close_list(out, list)
      out << "</#{list}>\n" if list
      nil
    end
  end
end
