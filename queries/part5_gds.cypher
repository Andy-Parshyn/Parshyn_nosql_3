// =============================================================================
// Частина 5 — Графові алгоритми через GDS (Graph Data Science 2.6.x)
//   cat queries/part5_gds.cypher | docker exec -i neo4j_movielens \
//        cypher-shell -u neo4j -p password123
// GDS не працює зі збереженим графом напряму — спершу створюємо проєкцію в памʼяті.
// =============================================================================


// #############################################################################
// 5.1 PageRank на графі ФІЛЬМІВ
// Будуємо граф, де фільми звʼязані, якщо їх обидва високо оцінили ті самі
// користувачі (weight = к-сть таких користувачів).
// #############################################################################

// Підстраховка: прибрати стару проєкцію/ребра, якщо лишилися від попереднього запуску
CALL gds.graph.drop('movieGraph', false) YIELD graphName RETURN graphName;
MATCH ()-[co:CO_RATED]-() DELETE co;

// Крок 1: матеріалізуємо ребра фільм-фільм через спільних користувачів.
// Замість дорогого degree-фільтра через pattern-comprehension використовуємо
// поріг weight >= 10 (вже обчислена к-сть спільних користувачів) — це і відсікає
// шумові звʼязки, і значно швидше. id(m1)<id(m2) рахує кожну пару один раз.
MATCH (m1:Movie)<-[r1:RATED]-(u:User)-[r2:RATED]->(m2:Movie)
WHERE r1.rating >= 4 AND r2.rating >= 4 AND id(m1) < id(m2)
WITH m1, m2, count(u) AS weight
WHERE weight >= 10
WITH m1, m2, weight
ORDER BY weight DESC
LIMIT 50000
MERGE (m1)-[co:CO_RATED]-(m2)
SET co.weight = weight;

// Крок 2: проєкція в памʼяті GDS (native projection).
CALL gds.graph.project(
  'movieGraph',
  'Movie',
  { CO_RATED: { orientation: 'UNDIRECTED', properties: 'weight' } }
)
YIELD graphName, nodeCount, relationshipCount;

// Крок 3: PageRank (зважений). Топ-10 найвпливовіших фільмів.
// gds.util.asNode(nodeId) повертає вузол за внутрішнім id.
CALL gds.pageRank.stream('movieGraph', {
  maxIterations: 20,
  dampingFactor: 0.85,
  relationshipWeightProperty: 'weight'
})
YIELD nodeId, score
RETURN gds.util.asNode(nodeId).title AS movie, round(score, 4) AS pageRank
ORDER BY pageRank DESC
LIMIT 10;

// Крок 4: прибираємо проєкцію та тимчасові ребра.
CALL gds.graph.drop('movieGraph', false) YIELD graphName RETURN graphName;
MATCH ()-[co:CO_RATED]-() DELETE co;


// #############################################################################
// 5.2 Louvain — спільноти користувачів зі схожими смаками
// Граф: користувачі звʼязані, якщо обидва високо оцінили спільні фільми.
// Поріг rating = 5 (а не >=4) — тримає к-сть user-user пар керованою на повному
// 1M датасеті (інакше популярні фільми дають мільйони пар і ризик OOM).
// #############################################################################

CALL gds.graph.drop('userSimilarity', false) YIELD graphName RETURN graphName;
MATCH ()-[sim:SIMILAR]-() DELETE sim;

// Крок 1: матеріалізуємо ребра користувач-користувач через спільні фільми.
MATCH (u1:User)-[r1:RATED]->(m:Movie)<-[r2:RATED]-(u2:User)
WHERE r1.rating = 5 AND r2.rating = 5 AND id(u1) < id(u2)
WITH u1, u2, count(m) AS weight
WHERE weight >= 5
WITH u1, u2, weight
ORDER BY weight DESC
LIMIT 50000
MERGE (u1)-[sim:SIMILAR]-(u2)
SET sim.weight = weight;

// Крок 2: проєкція (спільна для 5.2 і 5.3).
CALL gds.graph.project(
  'userSimilarity',
  'User',
  { SIMILAR: { orientation: 'UNDIRECTED', properties: 'weight' } }
)
YIELD graphName, nodeCount, relationshipCount;

// Крок 3: Louvain — 10 найбільших спільнот за розміром.
CALL gds.louvain.stream('userSimilarity', { relationshipWeightProperty: 'weight' })
YIELD nodeId, communityId
RETURN communityId, count(*) AS size
ORDER BY size DESC
LIMIT 10;

// Крок 3b: якість розбиття — modularity (без запису у БД).
CALL gds.louvain.stats('userSimilarity', { relationshipWeightProperty: 'weight' })
YIELD communityCount, modularity, ranLevels
RETURN communityCount, round(modularity, 4) AS modularity, ranLevels;

// Крок 3c: топ-3 жанри для 5 найбільших спільнот (за високо-оціненими фільмами).
CALL gds.louvain.stream('userSimilarity', { relationshipWeightProperty: 'weight' })
YIELD nodeId, communityId
WITH communityId, gds.util.asNode(nodeId) AS u
WITH communityId, collect(u) AS members, count(*) AS size
ORDER BY size DESC
LIMIT 5
UNWIND members AS u
MATCH (u)-[r:RATED]->(m:Movie)-[:HAS_GENRE]->(g:Genre)
WHERE r.rating >= 4
WITH communityId, size, g.name AS genre, count(*) AS cnt
ORDER BY communityId, cnt DESC
WITH communityId, size, collect(genre)[0..3] AS top3Genres
RETURN communityId, size, top3Genres
ORDER BY size DESC;


// #############################################################################
// 5.3 Найкоротший шлях між користувачами (Dijkstra)
// Використовуємо ту саму проєкцію 'userSimilarity'.
// УВАГА: Dijkstra МІНІМІЗУЄ суму ваг. У нас weight = к-сть спільних фільмів
// (більше = схожіші), тож "сирий" Dijkstra обере НАЙМЕНШ схожі хопи. Нижче два
// варіанти: (A) сирий (мін. сума weight) і (B) з інвертованою вартістю 1.0/weight
// для семантики "найсхожіший шлях". Перед запуском оберіть звʼязану пару (Крок 0).
// #############################################################################

// Крок 0: знайти пару користувачів, що точно лежать в одній компоненті (мають
// шлях). Беремо два кінці найважчого ребра + сусіда — гарантовано звʼязані.
// (Під час виконання підставте знайдені userId у запити нижче.)
MATCH (a:User)-[s:SIMILAR]-(b:User)
RETURN a.userId AS userA, b.userId AS userB, s.weight AS w
ORDER BY w DESC LIMIT 5;

// (A) Сирий Dijkstra (мінімальна сума ваг). Пара 4277/4169 — два активні хаби, що
// гарантовано присутні у проєкції (підставте інші userId за бажанням; кандидатів
// дає Крок 0 вище).
MATCH (source:User {userId: 4277}), (target:User {userId: 4169})
CALL gds.shortestPath.dijkstra.stream('userSimilarity', {
  sourceNode: source,
  targetNode: target,
  relationshipWeightProperty: 'weight'
})
YIELD index, totalCost, nodeIds, costs
RETURN totalCost,
       size(nodeIds) - 1 AS hops,
       [nodeId IN nodeIds | gds.util.asNode(nodeId).userId] AS userChain,
       costs;

// (B) Семантично коректний "найсхожіший шлях": інвертуємо вагу у властивість cost.
// (Запускати лише за потреби — потребує запису cost у ребра SIMILAR.)
// MATCH ()-[s:SIMILAR]-() SET s.cost = 1.0 / s.weight;
// CALL gds.graph.drop('userSimilarity', false) YIELD graphName RETURN graphName;
// CALL gds.graph.project('userSimilarity','User',
//   { SIMILAR: { orientation:'UNDIRECTED', properties:'cost' } }) YIELD nodeCount;
// MATCH (source:User {userId: 4277}), (target:User {userId: 4169})
// CALL gds.shortestPath.dijkstra.stream('userSimilarity',
//   { sourceNode: source, targetNode: target, relationshipWeightProperty: 'cost' })
// YIELD totalCost, nodeIds
// RETURN totalCost, size(nodeIds)-1 AS hops,
//        [n IN nodeIds | gds.util.asNode(n).userId] AS userChain;

// Крок прибирання (після завершення 5.2 і 5.3):
CALL gds.graph.drop('userSimilarity', false) YIELD graphName RETURN graphName;
MATCH ()-[sim:SIMILAR]-() DELETE sim;
