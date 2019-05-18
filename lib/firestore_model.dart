library firestore_model;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
// ignore: deprecated_member_use
import 'package:collection/equality.dart';
import 'package:synchronized_lite/synchronized_lite.dart';

import 'package:mutable_model/mutable_model.dart';

abstract class FirestoreMetaModel extends StoredMetaModel {
  static final id = Prop<DocumentReference>();

  CollectionReference get collectionRef;

  @override
  List<Property> get properties => StoredMetaModel.storedModelProperties + <Property>[FirestoreMetaModel.id] + List.castFrom<StoredProperty, Property>(cachedAttrs) + extraProperties;

  List<Property> get extraProperties => [];

}

abstract class FirestoreModel extends StoredModel with Lock {

  FirestoreModel(FirestoreMetaModel meta): super(meta);

  @override
  FirestoreMetaModel get meta => super.meta as FirestoreMetaModel;

  bool get exists => data != null;
  DocumentReference get docRef => get(FirestoreMetaModel.id);
  set docRef(DocumentReference value) => set(FirestoreMetaModel.id, value);

  void init(DocumentSnapshot snapshot) {
    assert(snapshot.exists);
    this.docRef = snapshot.reference;
    readFrom(snapshot.data);
    flushChanges();
  }

  Future<DocumentReference> create() async {
    await save();
    return docRef;
  }

  Future<bool> save() async {
    return await synchronized<bool>(() async {
      try {
        if(docRef != null) {
          var changes = getChanges();
          print("${docRef.path}: save: ${changes.keys.toList()}");
          if(changes.length == 0)
            return false;
          saving = true;
          flushChanges();
          await docRef.setData(changes, merge: true);
          loaded = true;
          if(data == null)
            data = changes;
          else
            data.addAll(changes);
        } else {
          saving = true;
          data = createData();
          flushChanges();
          print("${meta.collectionRef.path}: create: ${data.keys.toList()}");
          docRef = await meta.collectionRef.add(data);
        }
        return true;
      } finally {
        saving = false;
        flushChanges();
      }
    });
  }

  bool loadFromSnapshot(DocumentSnapshot doc) {
    readFrom(doc.data);
    docRef = doc.reference;
    loaded = true;
    return flushChanges();
  }

  Future<void> load(String id) async {
    if(id == null)
      return;
    var doc = await meta.collectionRef.document(id).get();
    loadFromSnapshot(doc);
  }

  void initTemplate() {
    data = createData();
  }

  Map<String, dynamic> getTemplateData() {
    return getChanges();
  }

}

typedef T ElementFactory<T>(DocumentSnapshot doc);

StreamSubscription<QuerySnapshot> createModelSubscription<T extends FirestoreModel>({
  ModelMap<String, T>collection,
  ElementFactory<T> factory,
  Query query}) {
  return query.snapshots().listen(
    (snapshots) {
      for(var change in snapshots.documentChanges) {
        var doc = change.document;
        if(change.type == DocumentChangeType.removed) {
          collection.remove(doc.documentID);
        } else if(collection.containsKey(doc.documentID)) {
          collection[doc.documentID].loadFromSnapshot(doc);
        } else {
          collection.put(doc.documentID,  factory(doc));
        }
      }
      collection.loaded = true;
    }
  );
}

class Attribute<T> extends StoredProperty<T> {

  Attribute(String name, Property<T> attr): super(name, attr);

  @override
  dynamic readFrom(Map<dynamic, dynamic> data) {
    if(!data.containsKey(name)) {
      return null;
    } else {
      return data[name];
    }
  }

  @override
  void writeTo(dynamic modelData, Map<dynamic, dynamic> data) {
    data[name] = modelData;
  }

  void calcChanges(dynamic modelData, Map<dynamic, dynamic> data, Map<dynamic, dynamic> changes) {
    if(!data.containsKey(name) || !dataEquals(modelData, data[name]))
      changes[name] = modelData;
  }

  Query whereEquals(T value, Query src) {
    return src.where(name, isEqualTo: prop.store(value));
  }

  Query whereLessThan(T value, Query src) {
    return src.where(name, isLessThan: prop.store(value));
  }

  Query orderBy(Query src, {descending: false}) {
    return src.orderBy(name, descending: descending);
  }

  Query startAt(T value, Query src) {
    return src.startAt([prop.store(value)]);
  }

  Query startAfter(T value, Query src) {
    return src.startAfter([prop.store(value)]);
  }

  Query endBefore(T value, Query src) {
    return src.endBefore([prop.store(value)]);
  }

  Query endAt(T value, Query src) {
    return src.endAt([prop.store(value)]);
  }
}

class ListAttribute<T> extends StoredProperty<List<T>> {

  String get prefix => name;

  ListAttribute(String prefix, ListProp<T> prop): super(prefix, prop);

  @override
  dynamic readFrom(Map<dynamic, dynamic> data) {
    final list = List<dynamic>();
    while(true) {
      var key = '$prefix${list.length}';
      if(!data.containsKey(key))
        break;
      list.add(data[key]);
    }
    return list;
  }

  @override
  void writeTo(dynamic modelData, Map<dynamic, dynamic> data) {
    final list = modelData as List;
    if(list != null) {
      for(var i = 0; i < list.length; i++) {
        var key = '$prefix$i';
        data[key] = list[i];
      }
    }
  }

  void calcChanges(dynamic modelData, Map<dynamic, dynamic> data, Map<dynamic, dynamic> changes) {
    if(modelData is List) {
      for(var i = 0; i < modelData.length; i++) {
        var key = '$prefix$i';
        if(!data.containsKey(key) || !(prop as ListProp<T>).element.dataEquals(modelData[i], data[key]))
          changes[key] = modelData[i];
      }
    }
  }
  
}

class TimestampProperty extends Prop<DateTime> {

  TimestampProperty([DateTime initialValue]): super(initialValue);

  @override
  DateTime load(dynamic data) {
    if(data is FieldValue)
      return null; // Special handling for server timestamp
    if(data == null)
      return null;
    if(data is DateTime)
      return data;
    final ts = data as Timestamp;
    return DateTime.fromMicrosecondsSinceEpoch(ts.microsecondsSinceEpoch, isUtc: true);
  }

  @override
  dynamic store(DateTime dt) {
    return dt == null ? null : Timestamp.fromMicrosecondsSinceEpoch(dt.toUtc().microsecondsSinceEpoch);
  }

  dynamic serverTimestamp() {
    return FieldValue.serverTimestamp();
  }

}

class TimestampAttr extends Attribute<DateTime> {

  TimestampAttr(String name, [DateTime initialValue]): super(name, TimestampProperty(initialValue));

  dynamic serverTimestamp() {
    return (prop as TimestampProperty).serverTimestamp();
  }

}

/// Stores GeoPoint value as-is
class GeoPointProp extends Prop<GeoPoint> {

  GeoPointProp([GeoPoint initialValue]): super(initialValue);

}

/// Stores a document reference
class DocRefProp extends Prop<DocumentReference> {

  DocRefProp([DocumentReference initialValue]): super(initialValue);

  @override
  DocumentReference load(data) {
    if(data is DocumentReference)
      return data;
    else
      return null;
  }

  @override
  dynamic store(DocumentReference dr) {
    if(dr == null)
      return null;
    else {
      return dr;
    }
  }

}

typedef T Factory<T>();

/// Stores the entire model as a value. Does not store model's ID
class StoredModelProp<M extends StoredModel> extends MapProp<M> {

  final Factory<M> factory;
  final List<StoredProperty> storedAttrs;
  final bool allowNull;

  StoredModelProp(this.factory, this.storedAttrs, {this.allowNull = true});

  @override
  M load(data) {
    if(data == null) {
      return allowNull ? null: factory();
    } else {
      M model = factory();
      model.readFrom(Map.castFrom<dynamic, dynamic, String, dynamic>(data), storedAttrs);
      return model;
    }
  }

  @override
  dynamic store(M model) {
    if(model == null && allowNull) {
      return null;
    } else {
      return (model ?? factory()).createData(storedAttrs);
    }
  }
  
}
