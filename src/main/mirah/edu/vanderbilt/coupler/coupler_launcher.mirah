import java.lang.ClassLoader
import java.lang.Thread
import java.io.File
import java.io.FileOutputStream
import java.io.FilenameFilter
import java.net.URL
import java.net.HttpURLConnection
import java.net.URLClassLoader
import java.util.ArrayList
import java.util.Date
import java.util.regex.Pattern
import java.text.SimpleDateFormat
import org.jsoup.Jsoup

class CouplerContainer < Thread
  def initialize(class_loader:URLClassLoader, local_coupler_jar:File)
    @class_loader = class_loader
    @local_coupler_jar = local_coupler_jar
  end

  def getContextClassLoader
    ClassLoader(@class_loader)
  end

  def run:void
    klass = Class.forName("org.jruby.embed.ScriptingContainer")
    container = klass.newInstance

    parameter_types = Class[1]; parameter_types[0] = String.class
    method = klass.getDeclaredMethod("runScriptlet", parameter_types)
    load_path = "file:" + @local_coupler_jar.toURI.getSchemeSpecificPart + "!/META-INF/coupler.home/lib"
    args = Object[1]
    args[0] = <<-EOF
      # tell jRuby's classloader about the jar
      require '#{@local_coupler_jar.getAbsolutePath}'

      # put coupler.home/lib in the load path
      $LOAD_PATH.unshift("#{load_path}")

      require 'coupler'
      begin
        Coupler::Runner.new([])
      rescue SystemExit
      end
    EOF
    method.invoke(container, args)
  end
end

class CouplerLauncher
  def initialize
    @latest_available_jar_url = URL(nil)
    find_coupler_dir
    find_latest_available_jar
    install_latest_available_jar
    run_coupler
  end

  def find_coupler_dir:void
    user_home = System.getProperty("user.home")
    @coupler_dir = File.new(File.new(user_home), user_home.startsWith("/") ? ".coupler" : "coupler")
    if !@coupler_dir.exists
      @coupler_dir.mkdir
    end
  end

  def find_latest_available_jar:void
    github_url = "https://github.com/coupler/coupler/downloads"
    doc = Jsoup.connect(github_url).get
    elts = doc.select('ol#manual_downloads')
    if elts.size == 0
      return
    end
    ol = elts.get(0)

    date_formatter = SimpleDateFormat.new("EEE MMM d HH:mm:ss zzz yyyy")
    latest_date = Date.new(long(0))
    latest_href = String(nil)
    lis = ol.select('li')
    i = 0
    while i < lis.size
      li = lis.get(i)

      links = li.select('h4 a')
      if links.size == 0
        next
      end

      abbrs = li.select('abbr')
      if abbrs.size == 0
        next
      end
      abbr = abbrs.get(0)
      date = date_formatter.parse(abbr.html)
      if latest_date.compareTo(date) < 0
        latest_date = date
        latest_href = links.get(0).attr('href')
      end
      i += 1
    end
    if latest_href != nil
      @latest_available_jar_url = URL.new(URL.new(github_url), latest_href)
    end
  end

  def install_latest_available_jar:void
    if @latest_available_jar_url == nil
      return
    end
    # get the basename
    pattern = Pattern.compile(".*?([^/]*)$");
    matcher = pattern.matcher(@latest_available_jar_url.toString)
    if !matcher.matches
      return
    end

    basename = matcher.group(1)
    @local_coupler_jar = File.new(@coupler_dir, basename)
    if @local_coupler_jar.exists
      return
    end

    # grab the new jar file
    puts "There's a new Coupler version available. Fetching..."

    # github's download urls are probably redirections, which
    # sucks because they redirect from https to http, which
    # HttpURLConnection won't follow because of security issues
    conn = HttpURLConnection(@latest_available_jar_url.openConnection)
    response_code = conn.getResponseCode
    while response_code == 302
      @latest_available_jar_url = URL.new(@latest_available_jar_url, conn.getHeaderField('Location'))
      conn = HttpURLConnection(@latest_available_jar_url.openConnection)
    end
    if response_code != 200
      puts "Something went wrong when downloading the Coupler update: #{conn.getResponseMessage}"
      puts "Aborting... :("
      return
    end

    reader = conn.getInputStream
    writer = FileOutputStream.new(@local_coupler_jar)
    buffer = byte[131072]
    total_bytes_read = 0
    bytes_read = reader.read(buffer)
    while bytes_read > 0
      total_bytes_read += bytes_read
      puts "#{total_bytes_read / 1024}KB"
      writer.write(buffer, 0, bytes_read)
      bytes_read = reader.read(buffer)
    end
    writer.close
    reader.close
    puts "Done fetching."

    # unlink old jars
    @coupler_dir.listFiles.each do |f|
      if f.getPath.endsWith(".jar") && f.compareTo(@local_coupler_jar) != 0
        f.delete
      end
    end
  end

  def run_coupler:void
    pattern = Pattern.compile("^coupler-[a-f0-9]+.jar$");
    urls = URL[1]; urls[0] = @local_coupler_jar.toURL
    puts urls[0].toString
    cl = URLClassLoader.new(urls)
    thr = CouplerContainer.new(cl, @local_coupler_jar)
    thr.start
  end
end

CouplerLauncher.new