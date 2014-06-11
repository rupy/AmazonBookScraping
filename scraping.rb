# coding: utf-8

require "amazon/ecs"
require "open-uri"
require 'sqlite3'

#
#= Amazon.comから書籍の目次を取り出すためのライブラリ
#
class AmazonBookScraping

  #== アソシエイトタグ
  attr_reader :assosiate_tag

  #== アクセスキー
  attr_reader :access_key

  #== シークレットキー
  attr_reader :secret_key

  #== 国
  attr_reader :country

  #== エラー時の再試行回数
  MAX_RETRY = 10

  #== 再試行のための待ち時間(second)
  RETRY_TIME = 2

  #== sqlite3のDBの内容を保存するファイル名
  DB_FILENAME = "book_info.db"

  #
  #= 初期化
  #
  def initialize(assosiate_tag, access_key, secret_key, country = 'jp')
    @assosiate_tag = assosiate_tag
    @access_key = access_key
    @secret_key = secret_key
    @country = country

    configure
  end

  #
  #= AmazonAPIの初期設定
  #
  def configure
    Amazon::Ecs.configure do |options|
      options[:associate_tag] = @assosiate_tag
      options[:AWS_access_key_id] = @access_key
      options[:AWS_secret_key] = @secret_key
      options[:country] = @country
    end
  end

  #
  #= APIレスポンスに対する総ページ数（APIの制限から最大10ページだが，それ以上あってもその値を返却する）
  #
  def total_pages
    resp = try_and_retry do
      yield
    end
    #puts resp.marshal_dump
    pages = resp.total_pages.to_i
    #puts "total pages:" + pages.to_s
    pages
  end

  #
  #= ブロックで受け取った処理を試行し，エラーが出たら一定数再試行
  #
  def try_and_retry
    retry_count = 0
    # 立て続けにたくさんのデータを取ってきていると、APIの制限に引っかかってエラーを出すことがある。
    # その場合にはしばらく待って、再度実行する
    resp = nil
    begin
      resp = yield
    rescue Amazon::RequestError => e
      if /503/ =~ e.message && retry_count < MAX_RETRY
        # puts e.message
        puts "retry_count:" + retry_count.to_s
        sleep(RETRY_TIME * retry_count)
        retry_count += 1
        retry
      else
        raise e
      end
    end
    resp
  end

  #
  #= ASINの配列を取得
  #
  def get_asin(query,max_page=0)
    result = []

    # 繰り返すページ数を求める
    if max_page == 0
      max_page = total_pages do
        Amazon::Ecs.item_search(query, {:item_page => page})
      end
    end
    max_page = 10 if max_page > 10

    for page in 1..max_page
      retry_count = 0
      puts "page: " + page.to_s
      resp = try_and_retry do
        Amazon::Ecs.item_search(query, {:item_page => page})
      end
      # puts resp.marshal_dump

      resp.items.each do |item|
        result.push(item.get("ASIN"))
      end
    end
    result
  end

  #
  #= browsenodeを取得
  #
  def get_browsenode(node_id, response_group=:TopSellers)
    options = {}
    # デフォルト値: BrowseNodeInfo
    # 有効な値: MostGifted | NewReleases | MostWishedFor | TopSellers
    options[:ResponseGroup] = response_group
    resp = try_and_retry do
      Amazon::Ecs.browse_node_lookup(node_id, options)
    end
    puts resp.marshal_dump
  end

  #
  #= BrowseNodeが子供を持っているか
  #
  def has_children?(node)
    # node.sizeは<childlen>タグを持っていれば1，持っていなければ0になる
    node.size != 0
  end

  #
  #= browsenode_idからasinを取得
  #
  def get_asin_by_browsenode(browsenode_id, max_page=0)

    result = []

    # 繰り返すページ数を求める
    if max_page == 0
      max_page = total_pages do
        Amazon::Ecs.item_search("" , { :browse_node => browsenode_id})
      end
    end
    max_page = 10 if max_page > 10

    for page in 1..max_page

      resp = try_and_retry do
        Amazon::Ecs.item_search("" , { :browse_node => browsenode_id, :item_page => page})
      end

      # puts res.marshal_dump
      resp.items.each do |item|
        puts title = item.get("ItemAttributes/Title")
        asin = item.get("ASIN")
        result.push(asin)
      end
      puts "============="
    end
    result

  end

  #
  #= asin(isbn)から情報を取得する
  #
  def get_bookinfo_by_asin(asin)

    resp = try_and_retry do
      Amazon::Ecs.item_lookup(asin.to_s, :response_group => 'Small, ItemAttributes, Images')
    end

    # puts resp.marshal_dump
    result = nil
    resp.items.each do |item|
      result = {
          title:        item.get('ItemAttributes/Title'),
          author:       item.get_array('ItemAttributes/Author').join(", "),
          manufacturer: item.get('ItemAttributes/Manufacturer'),
          group:        item.get('ItemAttributes/ProductGroup'),
          url:          item.get('DetailPageURL'),
          amount:       item.get('ItemAttributes/ListPrice/Amount')
      }
    end
    result
  end

  #
  #= スクレイピングをしてAMAZONから目次を取得する
  #
  def get_contents(asin)

    result = ""

    # asinを基にURLを決定
    @url = "http://www.amazon.co.jp/gp/product/toc/" + asin.to_s

    # URLのリソースを取得
    charset = nil
    html = open(@url) do |f|
      charset = f.charset
      f.read
    end

    # Nokogiriでパースする
    @doc = Nokogiri::HTML.parse(html, nil, charset)

    # 目次がない場合
    if @doc.xpath("//div[@class='content']//p").count == 0
      puts asin.to_s + "目次がありません"
      return ""
    end

    # 目次を解析
    @doc.xpath("//div[@class='content']//p").each do |content|

      # content.textの場合は正常に表示されるのに，content.inner_htmlの時には何故か文字化けする
      # encodeがそのままなのが問題なようなので，UTF-8に変換する．
      html = content.inner_html.encode('UTF-8')
      # htmlタグを削除
      result = html.gsub(/<\s*br\s*>/,"\n").gsub(/<[^>]+>/,"")

    end
    result
  end

  #
  #= データベースに格納するためのテーブルを作成
  #
  def create_table
    db = SQLite3::Database.new(DB_FILENAME)
    create_table_sql = <<-SQL
CREATE TABLE book_info (
  id            integer PRIMARY KEY AUTOINCREMENT,
  title         text,
  asin          text,
  node_id       integer,
  browsenode    text,
  author        text,
  manufacturer  text,
  url           text,
  amount        integer,
  contents      text
);
    SQL

    begin
      db.execute(create_table_sql)
    rescue SQLite3::SQLException => e
      puts e.message
    ensure
      db.close
    end
  end

  #
  #= データベースにデータを格納する
  #
  def save_data(book_info=nil)
    db = SQLite3::Database.new(DB_FILENAME)
    insert_sql = "INSERT INTO book_info VALUES (NULL, :title, :asin, :node_id, :browsenode, :author, :manufacturer, :url, :amount, :contents);"

    begin
      db.execute(insert_sql,
                 title:         book_info[:title],
                 asin:          book_info[:asin],
                 node_id:    book_info[:node_id],
                 browsenode:    book_info[:browsenode],
                 author:        book_info[:author],
                 manufacturer:  book_info[:manufacturer],
                 url:           book_info[:url],
                 amount:        book_info[:amount],
                 contents:      book_info[:contents])

    rescue SQLite3::SQLException => e
      puts e.message
    ensure
      db.close
    end
  end

  #
  #= すでにasinのものが登録されているかどうか
  #
  def already_registered?(asin)
    db = SQLite3::Database.new(DB_FILENAME)
    select_sql = "SELECT COUNT(*) FROM book_info WHERE asin = :asin;"
    begin
      count = db.execute(select_sql, asin: asin)
    rescue SQLite3::SQLException => e
      puts e.message
    ensure
      db.close
    end
    (count[0][0] > 0)
  end

  #
  #= node_idからブラウズノードのパスを取得
  #
  def get_browsenode_path(node_id)
    options = {}
    resp = try_and_retry do
      Amazon::Ecs.browse_node_lookup(node_id, options)
    end
    puts resp.marshal_dump

    # Nokogiri形式のデータをパースする
    browsenode = resp.doc.xpath("//BrowseNodes/BrowseNode")
    name = browsenode.xpath("Name")
    all_browsenode_path = name.text

    # 先祖がいればたどる
    parent = browsenode.xpath("Ancestors")

    while has_children? parent
      # 先祖あり
      parent_node_name = parent.xpath("BrowseNode/Name")
      all_browsenode_path = "#{parent_node_name.text}/#{all_browsenode_path}"
      parent = parent.xpath("BrowseNode/Ancestors")
    end
    "/" + all_browsenode_path
  end

  #
  #= browsenodeをたどっていき，末尾のノードから得られるすべてのasinを用いて，目次を取得する
  #
  def store_bookinfo_from_browsenode(node_id, prefix="", first_node_id=nil)

    # browsenode情報を取ってくる
    resp = try_and_retry do
      Amazon::Ecs.browse_node_lookup(node_id)
    end

    # Nokogiri形式のデータをパースする
    browsenode = resp.doc.xpath("//BrowseNodes/BrowseNode")
    name = browsenode.xpath("Name")
    all_browsenode_path = prefix + "/" + name.text
    puts "NodePath: " + all_browsenode_path

    # 子供がいればたどる
    children = browsenode.xpath("Children")
    if has_children? children
      # 子供あり
      children_nodes = children.xpath("BrowseNode/BrowseNodeId").each do |child_id|
        # puts "NodeID:" + child_id.text
        # 再帰
        store_bookinfo_from_browsenode(child_id.text, all_browsenode_path)
      end
    else
      # 子供がなく，末尾（葉）
      # カテゴリに属する書籍のasinを取得
      asin_array = get_asin_by_browsenode(node_id)
      asin_array.each do |asin|
        # DB上に重複がなければ
        unless already_registered? asin
          book_info = get_bookinfo_by_asin(asin)
          contents = get_contents(asin)
          info = {
              title:         book_info[:title],
              asin:          asin,
              node_id:       node_id,
              browsenode:    all_browsenode_path,
              author:        book_info[:author],
              manufacturer:  book_info[:manufacturer],
              url:           book_info[:url],
              amount:        book_info[:amount],
              contents:      contents
          }
          # DBに格納
          save_data info
        else
          # 重複
          puts "asin:'#{asin}' is already registered"
        end
      end
    end
  end

end
