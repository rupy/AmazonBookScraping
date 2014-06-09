# coding: utf-8

require "amazon/ecs"

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

  #== 言語
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
      begin
        resp = Amazon::Ecs.item_search(query, {:item_page => page})
          # puts resp.marshal_dump
          # 立て続けにたくさんのデータを取ってきていると、APIの制限に引っかかってエラーを出すことがある。
          # その場合にはしばらく待って、再度実行する
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
      resp.items.each do |item|
        result.push(item.get("ASIN"))
        # puts item.get("ItemAttributes/Title")
        # puts item.get("ItemAttributes/Manufacturer")
        # puts item.get("ItemAttributes/ProductGroup")
        # puts item.get("ItemAttributes/Author")
        # puts item.get_element("Author")
      end
    end
    result
  end

  #
  #= browsenodeを取得
  #
  def get_browsenode(node_id)
    options = {}
    # デフォルト値: BrowseNodeInfo
    # 有効な値: MostGifted | NewReleases | MostWishedFor | TopSellers
    options[:ResponseGroup] = :TopSellers
    resp = Amazon::Ecs.browse_node_lookup(node_id, options)
    puts resp.marshal_dump
  end

  #
  #= BrowseNodeInfoを取得
  #
  def get_browsenode_info(node_id)
    retry_count = 0

    resp = nil
    begin
      resp = Amazon::Ecs.browse_node_lookup(node_id)
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

    browsenode = resp.doc.xpath("//BrowseNodes/BrowseNode")
    name = browsenode.xpath("Name")
    puts "NodeName: " + name.text
    children = browsenode.xpath("Children")
    children_nodes = children.xpath("BrowseNode/BrowseNodeId").each do |child_id|
      puts "NodeID" + child_id.text
      # 再帰
      get_browsenode_info(child_id.text)
    end
  end

  #
  #= browsenode_idからasinを取得
  #
  def get_asin_from_browsenode(browsenode_id, max_pages=0)

    result = []

    max_pages = 10 if max_pages > 10
    for page in 1..max_pages

      retry_count = 0
      begin
        resp = Amazon::Ecs.item_search("" , { :browse_node => browsenode_id, :item_page => page})
      rescue Amazon::RequestError => e
        if /503/ =~ e.message && retry_count < MAX_RETRY
          puts e.message
          puts "retry_count:" + retry_count.to_s
          sleep(RETRY_TIME * retry_count)
          retry_count += 1
          retry
        else
        end
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
  def get_iteminfo_by_asin(asin)
    title = ""
    retry_count = 0
    begin
      resp = Amazon::Ecs.item_lookup(asin.to_s, :response_group => 'Small, ItemAttributes, Images')
    rescue Amazon::RequestError => e
      p e
      if /503/ =~ e.message && retry_count < MAX_RETRY
        puts e.message
        puts "retry_count:" + retry_count.to_s
        sleep(RETRY_TIME * retry_count)
        retry_count += 1
        retry
      else
      end
    end
    puts resp.marshal_dump
    resp.items.each do |item|
      puts "ASIN:#{item.get('ASIN')}"
      puts "Author:#{item.get_array('ItemAttributes/Author').join(", ")}"
      puts "Title:#{item.get('ItemAttributes/Title')}"
      puts "Manufacturer:#{item.get('ItemAttributes/Manufacturer')}"
      puts "Group:#{item.get('ItemAttributes/ProductGroup')}"
      puts "URL:#{item.get('DetailPageURL')}"
      puts "Amount:#{item.get('ItemAttributes/ListPrice/Amount')}"
    end
  end

end
