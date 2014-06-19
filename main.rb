# coding: utf-8

require "./scraping"

ASSOCIATE_TAG = "********"
ACCESS_KEY = "********"
SECRET_KEY = "********"
scraping = AmazonBookScraping.new(ASSOCIATE_TAG, ACCESS_KEY, SECRET_KEY)

# rubyというクエリに対するASINの配列を取得
puts scraping.get_asin("ruby")

# 465392（和書）に対して書籍のasinを取得する
puts scraping.get_asin_by_browsenode("465392")

# 4774165166（パーフェクトRuby on Rails）に対して情報を取得する
puts scraping.get_bookinfo_by_asin(4774165166)

# 4774165166（パーフェクトRuby on Rails）に対して目次をスクレイピングで取得する
puts scraping.get_contents(4774165166)

# browsenode（本/ジャンル別/文学・評論/文芸作品/日本文学）の先祖の配列を取得する
puts scraping.get_browsenode_ancestors(467250)

# 465392（本）のカテゴリに対して再帰的にbrowsenodeをたどっていき，
# 末尾のノードから得られるすべてのasinを用いて，目次を取得する
scraping.create_table
scraping.store_bookinfo_from_browsenode(465392, 507146)
