# coding: utf-8

require "amazon/ecs"
require "open-uri"
require 'sqlite3'
require 'sanitize'

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

    # DBオブジェクトの初期化
    @db = SQLite3::Database.new(DB_FILENAME)

    ObjectSpace.define_finalizer(self, self.class.close_db)
  end

  def self.close_db
    proc { @db.close }
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
        print "retry" if retry_count == 0
        print "."
        sleep(RETRY_TIME * retry_count)
        retry_count += 1
        retry
      else
        raise e
      end
    end
    puts "" if retry_count > 0
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
        Amazon::Ecs.item_search(query)
      end
    end
    max_page = 10 if max_page > 10

    for page in 1..max_page
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
  def has_child_nodes?(node)
    # node.sizeは子タグを持っていれば1以上，持っていなければ0になる
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
      puts "asin: " + asin.to_s + "は目次がありません"
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
      @db.execute(create_table_sql)
    rescue SQLite3::SQLException => e
      puts e.message
    end
  end

  #
  #= データベースにデータを格納する
  #
  def save_data(book_info=nil)
    insert_sql = <<-SQL
INSERT INTO
book_info
VALUES
(NULL, :title, :asin, :node_id, :browsenode, :author, :manufacturer, :url, :amount, :contents);
    SQL

    begin
      @db.execute(insert_sql,
                 title:         book_info[:title],
                 asin:          book_info[:asin],
                 node_id:       book_info[:node_id],
                 browsenode:    book_info[:browsenode],
                 author:        book_info[:author],
                 manufacturer:  book_info[:manufacturer],
                 url:           book_info[:url],
                 amount:        book_info[:amount],
                 contents:      book_info[:contents])

    rescue SQLite3::SQLException => e
      puts e.message
    end
  end

  #
  #= すでにasinのものが登録されているかどうか
  #
  def already_registered?(asin)
    select_sql = "SELECT COUNT(*) FROM book_info WHERE asin = :asin;"
    begin
      count = @db.execute(select_sql, asin: asin)
    rescue SQLite3::SQLException => e
      puts e.message
    end
    (count[0][0] > 0)
  end

  #
  #= node_idからブラウズノードのパスを取得
  #
  def get_browsenode_ancestors(node_id, print_flag=false)
    result = []
    options = {}
    resp = try_and_retry do
      Amazon::Ecs.browse_node_lookup(node_id, options)
    end
    #puts resp.marshal_dump

    # Nokogiri形式のデータをパースする
    browsenode = resp.doc.xpath("//BrowseNodes/BrowseNode")
    name = browsenode.xpath("Name")
    all_browsenode_path = name.text
    result.unshift name.text

    # 先祖がいればたどる
    parent = browsenode.xpath("Ancestors")

    while has_child_nodes? parent
      # 先祖あり
      parent_node_name = parent.xpath("BrowseNode/Name")
      result.unshift parent_node_name.text
      all_browsenode_path = "#{parent_node_name.text}/#{all_browsenode_path}"
      parent = parent.xpath("BrowseNode/Ancestors")
    end
    puts "/" + all_browsenode_path if print_flag

    result
  end

  #
  #= browsenodeをたどっていき，末尾のノードから得られるすべてのasinを用いて，目次を取得する
  #  first_node_idに前回中断した時のnode_idを入れることで，エラーが出ても途中から再開できる
  #
  def store_bookinfo_from_browsenode(node_id, first_node_id = nil, prefix = "")

    # browsenode情報を取ってくる
    resp = try_and_retry do
      Amazon::Ecs.browse_node_lookup(node_id)
    end

    # Nokogiri形式のデータをパースする
    browsenode = resp.doc.xpath("//BrowseNodes/BrowseNode")
    name = browsenode.xpath("Name").text
    all_browsenode_path = prefix + "/" + name
    puts "NodePath: " + all_browsenode_path

    # first_node_idが設定されていればチェックをする必要がある
    unless first_node_id.nil?
      # 親をたどる
      ancestors = get_browsenode_ancestors(first_node_id)
      # 開始する階層数
      bottom_level = ancestors.size - 1
      # 現在の階層
      current_level = ancestors.index(name)
      # 開始地点か
      if bottom_level == current_level
        puts "first node: " + name
      end
    end

    # 子供がいればたどる
    children = browsenode.xpath("Children")

    if has_child_nodes? children
      # 子供あり
      children.xpath("BrowseNode").each do |child_node|
        child_id = child_node.xpath("BrowseNodeId").text
        child_name = child_node.xpath("Name").text
        # first_node_idがnilならとりあえず解析を進めればいい
        # first_node_idが設定されていて，目的のノードならば解析を進める
        if first_node_id.nil? || ancestors[current_level + 1] == child_name
          # 再帰
          store_bookinfo_from_browsenode(child_id, first_node_id, all_browsenode_path)
          # 次からはskipしない
          first_node_id = nil
        # first_node_idが設定されているのに，目的のノードでない場合にはskipする
        else
          puts "skip: " + all_browsenode_path + "/" + child_name
        end
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
          puts "asin:'#{asin}'はすでに登録されています"
        end
      end
    end
  end

  #
  #= クラスタリングに不要な文字列を削除する前処理
  #
  def remove_structure_words(text)

    index_rex = %r!
(第?[0-9０-９IV一二三四五六七八九十序終]+\s*(章|節|部|話|回|週|時間目))                         #章や節の番号を除く
|((chapter|chap|part|tip|step|ステップ|case|lesson|フェーズ|phase)\.?-?\s*\d+\.?)           # 章や節の番号を除く
|(^\d[.:]\b)                                        #数字＋記号の文字列を除く（これも節を表すことが多い）
|(^\d+\.\d+(\.\d+)*)                                #1.2.3などの数字も節を表すことが多い
|(^[a-zA-Z\-]\.?\d+)                                # B.やA.2、-3も
|(^\d+\s+)                                          # 行頭のただの文字
|(^[0-9a-zA-Z]+-\d+)                                # 1-2-3など
|(^I{2,}\b)                                         # IIIなど
|(はじめに|初めに|introduction|まえがき|前書き|目次)
|(おわりに|終わりに|最後に|さいごに|あとがき|謝辞|エピローグ|epilogue|まとめ)
|(参考文献|索引|index|インデックス)
|((付録|巻末資料|appendix|特集)\s*[A-Z0-9]?\b?)         # 付録
|([　 ◆・■●【】．〔〕…※◯●：＜＞☆★]|ほか)             # 記号
|(-{2,})                                            # 長い線
|(^[\!-\/:-@\[-`{-~0-9\s]+)                         #記号と数字から始まる部分
!xi
    
    text = text
    .strip
    .gsub(index_rex,"")
    .strip
    .gsub(index_rex,"")
    .strip

    text = CGI.unescapeHTML(text)
    text = Sanitize.clean(text)
    text
  end

  def pre_processing()

    alter_sql = <<-SQL
ALTER TABLE book_info ADD COLUMN pre_processed_contents[text];
    SQL

    select_sql = <<-SQL
SELECT id, contents FROM book_info WHERE contents <> '';
    SQL

    update_sql = <<-SQL
UPDATE book_info SET pre_processed_contents = :pre_processed_contents WHERE id = :id;
    SQL

    begin
      puts "ALTER TABLE"
      @db.execute(alter_sql)
    rescue SQLite3::SQLException => e
      puts e.message
    end

    begin
      puts "UPDATE"
      @db.execute(select_sql) do |row|
        new_contents = remove_structure_words(row[1])
        book_info_id = row[0]
        @db.execute(update_sql,
          id: book_info_id,
          pre_processed_contents: new_contents)
      end
    rescue SQLite3::SQLException => e
      puts e.message
    end




  end

end
