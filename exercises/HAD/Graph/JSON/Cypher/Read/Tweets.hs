{-# LANGUAGE OverloadedStrings #-}

module Graph.JSON.Cypher.Read.Tweets where

-- provides functions for extracting tweets from graph-JSON

import Control.Arrow ((&&&), (>>>))
import Control.Monad (mplus, liftM2)
import Data.Aeson
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (mapMaybe, fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set

-- available in this git repository:

import Data.MultiMap (MultiMap)
import qualified Data.MultiMap as MM
import Data.Twitter
import Graph.JSON.Cypher.Read
import Graph.JSON.Cypher.Read.Graphs

{--
tweetFrom :: PropertiesJ -> Maybe RawTweet
tweetFrom (PJ props) = 
   RawT <$> props <<-$ "id_str" <*> props <<-$ "text"
        <*> props <<-$ "created_at" <*> props <<-# "favorites"

-- problem: not all tweets have these fields: some are just bare id's
-- I chose to reject these place-holders for now.

*Y2016.M08.D16.Solution> readGraphJSON twitterGraphUrl ~> tweets
*Y2016.M08.D16.Solution> let twit = last . nodes $ head tweets
*Y2016.M08.D16.Solution> twit ~> 
NJ {idn = "255",labels = ["Tweet"],propsn = PJ (fromList [("created_at",...)])}
*Y2016.M08.D16.Solution> tweetFrom (propsn twit) ~>
Tweet {idx = "727179491756396546", txt = "April 2016 @1HaskellADay...", ...}
--}

instance FromJSON RawTweet where
   parseJSON (Object o) = RawT <$> o .: "id_str" <*> o .: "text"
         <*> o .: "created_at" <*> o .: "favorites"

-- Using the above declaration, define the below

-- okay, for the indexed tweets, we now no longer need to determine an index
-- as the cypher query result generates one for its internal use and shares it
-- with us! Convenient.

indexedTweets :: [GraphJ] -> Map String RawTweet
indexedTweets = nodeMapper "Tweet"

{--
How many unique tweets are in the data set?
*Y2016.M08.D16.Solution> let idxt = indexedTweets tweets
*Y2016.M08.D16.Solution> length idxt ~> 33
--}

-- And with all the above we have:

readTweetsFrom :: FilePath -> IO [TimedTweet]
readTweetsFrom = fmap tweetsFrom . readGraphJSON

tweetsFrom :: [GraphJ] -> [TimedTweet]
tweetsFrom = map t2tt . Map.elems . indexedTweets

{--
*Y2016.M08.D16.Solution> fmap head (readTweetsFrom twitterGraphUrl) ~>
TT {date = 2016-05-20, time = 18:32:47, 
    twt = Tweet {idx = "733727186679672833", 
                 txt = "The weight's the thing\nWherein I'll catch the "
                    ++ "conscience of the King\n... no ... weight ...\nToday's "
                    ++ "#haskell solution https://t.co/XVqbPRfjAo",
                 created = "Fri May 20 18:32:47 +0000 2016",
                 favs = 1}}
--}

-- we want a set of indexed tweets from our graph-JSON

uniqueTweets :: [GraphJ] -> Set (Tweet String)
uniqueTweets = 
   indexedTweets           >>>
   Map.map t2tt            >>>
   Map.toList              >>>
   map (uncurry IndexedT)  >>>
   Set.fromList

{--
*Y2016.M08.D17.Solution> readGraphJSON twitterGraphUrl ~> tweets
*Y2016.M08.D17.Solution> let unqt = uniqueTweets tweets ~> length ~> 29
*Y2016.M08.D17.Solution> head (Set.toList unqt) ~>
IndexedT {index = "1134", tt = TT {date = 2016-05-20, ...}}
--}

-- URL -----------------------------------------------------------------

instance FromJSON URL where
   parseJSON (Object o) = URI <$> o .: "url"

twitterURLs :: [GraphJ] -> Map String URL
twitterURLs = nodeMapper "Link"   -- MUCH better!

-- notice how twitterURLs follows the same template as indexedTweets

-- so:

nodeMapper :: FromJSON a => String -> [GraphJ] -> Map String a
nodeMapper k = Map.fromList . mapMaybe (sequence . (idn &&& node2valM))
             . filter ((elem k) . labels) . concatMap nodes

-- USER -----------------------------------------------------------------

{--
So, yesterday we extracted URLs from twitter graph-JSON.

Today we'll extract users, or, in twitter-parlance: tweeps.

From the twitter graph-data at twitterGraphUrl, extract the users. The user
node data has the following structure:

{"id":"504",
 "labels":["User"],
 "properties":{"screen_name":"1HaskellADay",
               "name":"1HaskellADay",
               "location":"U.S.A.",
               "followers":1911,
               "following":304,
               "profile_image_url":"http://pbs.twimg.com/profile_images/437994037543309312/zkQSpXnp_normal.jpeg"}

Reify these data into a Haskell-type
--}

instance FromJSON User where
   parseJSON (Object o) =
      Tweep <$> o .: "screen_name" <*> o .: "name"
            <*> o .: "location"    <*> o .: "followers"
            <*> o .: "following"   <*> o .: "profile_image_url"

uniqueUsers :: [GraphJ] -> Map String User
uniqueUsers = nodeMapper "User"

{-- BONUS -----------------------------------------------------------------

From Read.Tweets we can get [GraphJ] of the nodes and relations. Answer the
below:

What is the distribution of tweets to users?
--}

type MMt = MultiMap User (Tweet String) (Set (Tweet String))

{--
Set is not a monad???

instance Applicative Set where
   pure x = Set.singleton x

instance Monad Set where
   return x = Set.singleton x
   join m   = Set.unions (Set.toList m)

join is not minimally-complete for monad definition???

Monad has to be Applicative???

My, my, my! The world does change quickly, doesn't it!
--}

userTweets :: [GraphJ] -> MMt
userTweets verse =
   let relates = concatMap rels verse
       users   = uniqueUsers verse
       tweets  = Map.fromList (map (index &&& id) (Set.toList (uniqueTweets verse)))
   in  foldr (addRow users tweets) (MM.MM Map.empty Set.singleton) relates

-- So, for each user, filter the relations of that user that also contains
-- a tweet id ... so tweets are better in a map

-- or, put another way, for each relation, if the relation has a tweet id and
-- a user id add that to the multimap in the maybe monad.

-- so, how to add a maybe key and a maybe value to a multimap ... justly?

type UserMap = Map String User
type TweetMap = Map String (Tweet String)

addRow :: UserMap -> TweetMap -> RelJ -> MMt -> MMt
addRow users tweets rel mm =
   fromMaybe mm (usertweet users tweets rel >>= \(u,t) -> 
                 return (MM.insert u t mm))  -- liftM/flip/uncurry... something

-- well, we need to know if there is a user-tweet relation!

usertweet :: UserMap -> TweetMap -> RelJ -> Maybe (User, Tweet String)
usertweet users tweets (RJ _ _ start end _) =
    liftM2 (,) (finduser start) (findtweet end)
    `mplus` liftM2 (,) (finduser end) (findtweet start)

-- which involves looking up values in the individual maps

      where findtweet = flip Map.lookup tweets
            finduser  = flip Map.lookup users

{--
*Y2016.M08.D19.Solution> let mm = userTweets rows
*Y2016.M08.D19.Solution> length (MM.store mm) ~> 7
*Y2016.M08.D19.Solution> let ans = Map.mapKeys name (Map.map length (MM.store mm))
*Y2016.M08.D19.Solution> mapM_ print (Map.toList ans)
("1HaskellADay",11)
("Aaron Levin",1)
("Amar Potghan",5)
("Edward Kmett",1)
("Francisco  T",1)
("Gabriel Gonzalez",1)
("geophf \217\8224",1)

TA-DAH!
--}
