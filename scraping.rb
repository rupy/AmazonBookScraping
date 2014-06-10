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
  #= クエリに対する総ページ数（APIの制限から最大10ページ）
  #
  def total_pages(query)
    resp = Amazon::Ecs.item_search(query, :item_page => 1)
    #puts resp.marshal_dump
    pages = resp.total_pages.to_i
    pages = 10 if pages > 10
    puts "total pages:" + pages.to_s
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
        puts e.message
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

    if max_page == 0
      max_page = total_pages(query)
    end

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
    resp = Amazon::Ecs.browse_node_lookup(node_id, options)
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
  #= BrowseNodeInfoを取得
  #
  def get_browsenode_info(node_id, prefix="")

    resp = try_and_retry do
      Amazon::Ecs.browse_node_lookup(node_id)
    end

    browsenode = resp.doc.xpath("//BrowseNodes/BrowseNode")
    name = browsenode.xpath("Name")
    all_browsenode_path = prefix + "/" + name.text
    puts "NodePath: " + all_browsenode_path
    children = browsenode.xpath("Children")

    if has_children? children
      # 子供あり
      children_nodes = children.xpath("BrowseNode/BrowseNodeId").each do |child_id|
        puts "NodeID:" + child_id.text
        # 再帰
        get_browsenode_info(child_id.text, all_browsenode_path)
      end
    else
      # 子供なし，末尾
      puts "末尾"
    end

  end

  #
  #= browsenode_idからasinを取得
  #
  def get_asin_by_browsenode(browsenode_id, max_pages=0)

    result = []

    max_pages = 10 if max_pages > 10
    for page in 1..max_pages

      resp = try_and_retry do
        Amazon::Ecs.item_search("" , { :browse_node => browsenode_id, :item_page => page})
      end

      # puts res.marshal_dump
      resp.items.each do |item|
        puts title = item.get("ItemAttributes/Title")
        asin = item.get("ASIN")
        result.push({:asin => asin, :title => title})
      end
      puts "============="
    end
    result

  end

  #
  #= asin(isbn)から情報を取得する
  #
  def get_item_by_asin(asin)

    resp = try_and_retry do
      Amazon::Ecs.item_lookup(asin.to_s, :response_group => 'Small, ItemAttributes, Images')
    end

    # puts resp.marshal_dump
    result = nil
    resp.items.each do |item|
      result = {
          author:       item.get_array('ItemAttributes/Author').join(", "),
          title:        item.get('ItemAttributes/Title'),
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
  def create_table(filename)
    db = SQLite3::Database.new(filename)
    create_table_sql = <<-SQL
CREATE TABLE book_info (
  id            integer PRIMARY KEY AUTOINCREMENT,
  title         text,
  asin          integer,
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
  def save_data(filename, book_info=nil)
    db = SQLite3::Database.new(filename)
    insert_sql = "INSERT INTO book_info VALUES (NULL, :title, :asin, :browsenode, :author, :manufacturer, :url, :amount, :contents);"

    begin
      db.execute(insert_sql,
                 title:         book_info[:title],
                 asin:          book_info[:asin],
                 browsenode:    book_info[:browse_node],
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
  def already_registered?(filename, asin)
    db = SQLite3::Database.new(filename)
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

end
