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

  #== エラー時の再試行回数
  MAX_RETRY = 10

  #== 再試行のための待ち時間(second)
  RETRY_TIME = 2

  #
  #= 初期化
  #
  def initialize(assosiate_tag, access_key, secret_key)
    @assosiate_tag = assosiate_tag
    @access_key = access_key
    @secret_key = secret_key

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
    end
  end

  #
  #= クエリに対する総ページ数（APIの制限から最大10ページ）
  #
  def total_pages(query)
    resp = Amazon::Ecs.item_search(query, :item_page => 1, :country => "jp")
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
        resp = Amazon::Ecs.item_search(query, :item_page => page, :country => "jp")
        # p resp
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
        puts item.get("ItemAttributes/Title")
        puts item.get("ItemAttributes/Manufacturer")
        puts item.get("ItemAttributes/ProductGroup")
        puts item.get("ItemAttributes/Author")
        # puts item.get_element("Author")
      end
    end
    result
  end
end
