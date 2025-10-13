#!/usr/bin/env ruby
# frozen_string_literal: true

require 'kramdown'
require 'fileutils'

class DocsBuilder
  GITHUB_URL = 'https://github.com/ismasan/steppe'

  def initialize(readme_path:, output_dir:)
    @readme_path = readme_path
    @output_dir = output_dir
    @sections = []
  end

  def build
    puts "Reading #{@readme_path}..."
    markdown = File.read(@readme_path)

    puts "Parsing markdown..."
    doc = Kramdown::Document.new(markdown, input: 'GFM', auto_ids: true)

    puts "Extracting structure..."
    extract_structure(doc.root)

    puts "Generating HTML..."
    html = generate_html(doc)

    puts "Writing to #{@output_dir}/index.html..."
    FileUtils.mkdir_p(@output_dir)
    File.write(File.join(@output_dir, 'index.html'), html)

    puts "Done! Documentation built successfully."
  end

  private

  def extract_structure(element, level = 0)
    element.children.each do |child|
      if child.type == :header
        # Use Kramdown's auto-generated ID
        id = child.attr['id']
        title = extract_text(child)

        @sections << {
          level: child.options[:level],
          id: id,
          title: title,
          element: child
        }
      end

      extract_structure(child, level + 1) if child.children
    end
  end

  def extract_text(element)
    case element.type
    when :text
      element.value
    when :codespan
      element.value
    when :header, :p, :strong, :em
      element.children.map { |c| extract_text(c) }.join if element.children
    else
      if element.children && !element.children.empty?
        element.children.map { |c| extract_text(c) }.join
      else
        ''
      end
    end
  end

  def generate_navigation
    nav_items = []
    current_section = nil

    @sections.each do |section|
      if section[:level] == 2
        current_section = section
        nav_items << %(<li><a href="##{section[:id]}">#{section[:title]}</a></li>)
      elsif section[:level] == 3 && current_section
        nav_items << %(<li class="nav-submenu"><a href="##{section[:id]}">#{section[:title]}</a></li>)
      end
    end

    nav_items.join("\n                ")
  end

  def generate_html(doc)
    # Convert markdown to HTML
    content_html = doc.to_html

    # Process the HTML to add proper structure
    content_html = wrap_sections(content_html)

    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Plumb - Composable types and pipelines for Ruby</title>
          <link rel="stylesheet" href="styles.css">
          <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css">
      </head>
      <body>
          <nav class="top-menu">
              <div class="top-menu-content">
                  <div class="top-menu-brand">
                      <span class="brand-name">Plumb</span>
                      <span class="brand-tagline">Data structures, validation, coercion and processing toolkit for Ruby</span>
                  </div>
                  <a href="#{GITHUB_URL}" target="_blank" class="github-link" aria-label="View on GitHub">
                      <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
                          <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
                      </svg>
                      <span>GitHub</span>
                  </a>
              </div>
          </nav>
          <div class="container">
              <nav class="sidebar">
                  <div class="logo">
                      <h2>Plumb</h2>
                      <p class="tagline">Composable typs and pipelines for Ruby</p>
                  </div>
                  <ul class="nav-menu">
                      #{generate_navigation}
                  </ul>
              </nav>

              <main class="content">
                  <header class="page-header">
                      <h1>Plumb</h1>
                      <p class="subtitle">Composable types and pipelines for Ruby</p>
                  </header>

                  #{content_html}
              </main>
          </div>
          <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
          <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/ruby.min.js"></script>
          <script>hljs.highlightAll();</script>
          <script>
              // Active section highlighting
              const observerOptions = {
                  root: null,
                  rootMargin: '-20% 0px -60% 0px',
                  threshold: 0
              };

              const sections = document.querySelectorAll('section, article[id]');
              const navLinks = document.querySelectorAll('.nav-menu a');

              // Create a map of href to link elements
              const linkMap = new Map();
              navLinks.forEach(link => {
                  const href = link.getAttribute('href');
                  if (href && href.startsWith('#')) {
                      linkMap.set(href, link);
                  }
              });

              const observer = new IntersectionObserver((entries) => {
                  entries.forEach(entry => {
                      if (entry.isIntersecting) {
                          const id = entry.target.getAttribute('id');
                          const activeLink = linkMap.get(`#${id}`);

                          if (activeLink) {
                              // Remove active class from all links
                              navLinks.forEach(link => link.classList.remove('active'));
                              // Add active class to current link
                              activeLink.classList.add('active');

                              // Update URL hash without scrolling
                              if (history.replaceState) {
                                  history.replaceState(null, null, `#${id}`);
                              } else {
                                  window.location.hash = id;
                              }
                          }
                      }
                  });
              }, observerOptions);

              // Observe all sections
              sections.forEach(section => {
                  if (section.id) {
                      observer.observe(section);
                  }
              });
          </script>
      </body>
      </html>
    HTML
  end

  def wrap_sections(html)
    # Remove the first h1 (title) as it's in the page header
    html = html.sub(/<h1[^>]*>.*?<\/h1>/, '')

    # Wrap h2 sections
    html.gsub!(/<h2 id="([^"]+)">(.+?)<\/h2>/) do
      id = $1
      title = $2
      if id == 'usage'
        %(</section>\n\n<section id="#{id}" class="section">\n<h2 id="#{id}">#{title}</h2>)
      else
        %(<section id="#{id}" class="section">\n<h2 id="#{id}">#{title}</h2>)
      end
    end

    # Wrap h3 subsections
    html.gsub!(/<h3 id="([^"]+)">(.+?)<\/h3>/) do
      id = $1
      title = $2
      %(</article>\n\n<article id="#{id}" class="subsection">\n<h3 id="#{id}">#{title}</h3>)
    end

    # Close any remaining open sections
    html += "\n</article>\n</section>" if html.include?('<section') || html.include?('<article')

    # Wrap first section (Overview)
    html = "<section id=\"overview\" class=\"section\">\n" + html

    # Clean up multiple closing tags
    html.gsub!(/(<\/article>\s*){2,}/, '</article>')
    html.gsub!(/(<\/section>\s*){2,}/, '</section>')

    html
  end

end

# Run the builder
if __FILE__ == $0
  readme_path = ARGV[0] || 'README.md'
  output_dir = ARGV[1] || 'website'

  unless File.exist?(readme_path)
    puts "Error: README file not found at #{readme_path}"
    exit 1
  end

  builder = DocsBuilder.new(
    readme_path: readme_path,
    output_dir: output_dir
  )

  builder.build
end
