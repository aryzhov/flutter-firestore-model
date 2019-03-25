library firestore_model;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
// ignore: deprecated_member_use
import 'package:collection/equality.dart';
import 'package:synchronized_lite/synchronized_lite.dart';

import 'package:mutable_model/mutable_model.dart';

abstract class FirestoreModel extends MutableModel<Property> with Lock {

  Map<String, dynamic> data;
  final id = SimpleProperty<DocumentReference>();
  final saving = BoolProp();
  final loaded = BoolProp();
  List<Property> _properties;

  List<StoredProperty> get attrs;

  List<Property> get properties {
    if(_properties == null)
      _properties = <Property>[saving, loaded, id] + attrs;
    return _properties;
  }

  CollectionReference get collectionRef;

  DocumentReference get docRef => id.value;
  set docRef(DocumentReference value) => id.value = value;

  get exists => docRef != null;

  void init(DocumentSnapshot snapshot) {
    assert(snapshot.exists);
    this.docRef = snapshot.reference;
    readFrom(snapshot.data);
  }

  void readFrom(Map<String, dynamic> data, [List<StoredProperty> attrs]) {
    if(data == null)
      return;
    for(var attr in attrs ?? this.attrs)
      attr.readFrom(data);
    this.data = data;
    loaded.value = true;
  }

  void writeTo(Map<String, dynamic> data, [List<StoredProperty> attrs]) {
    for(var attr in attrs ?? this.attrs)
      attr.writeTo(data);
  }

  Future<DocumentReference> create() async {
    await save();
    return docRef;
  }

  Future<bool> save() async {
    return await synchronized<bool>(() async {
      var newData = createData(attrs);
      try {
        if(exists) {
          var changes = getChanges(newData, data);
          print("${collectionRef.path}/$id: save: ${changes.keys.toList()}");
          if(changes.length == 0)
            return false;
          saving.value = true;
          flushChanges();
          await docRef.setData(changes, merge: true);
          loaded.value = true;
        } else {
          saving.value = true;
          flushChanges();
          print("${collectionRef.path}: create: ${newData.keys.toList()}");
          docRef = await collectionRef.add(newData);
        }
        data = newData;
        return true;
      } finally {
        saving.value = false;
        flushChanges();
      }
    });
  }

  bool loadFromSnapshot(DocumentSnapshot doc) {
    readFrom(doc.data);
    docRef = doc.reference;
    loaded.value = true;
    return flushChanges();
  }

  Future<void> load(String id) async {
    if(id == null)
      return;
    var doc = await collectionRef.document(id).get();
    loadFromSnapshot(doc);
  }

  void copyAttributesFrom(FirestoreModel other, [List<StoredProperty> props]) {
    List<Attribute> attrs = (props ?? this.attrs).where((attr) => attr is Attribute).map((attr) => attr as Attribute).toList();
    var attrMap = Map.fromEntries(attrs.map((attr) => MapEntry<String, StoredProperty>(attr.name, attr)));
    var data = Map<String, dynamic>();
    for(var attr0 in other.attrs) {
      if(attr0 is Attribute && attrMap.containsKey(attr0.name)) {
        var attr = attrMap[attr0.name];
        attr0.writeTo(data);
        attr.readFrom(data);
      }
    }
  }

  void initTemplate() {
    data = createData(attrs);
  }

  Map<String, dynamic> getTemplateData() {
    final newData = createData(attrs);
    final changes = getChanges(newData, data);
    return changes;
  }

}

typedef T ElementFactory<T>(DocumentSnapshot doc);

StreamSubscription<QuerySnapshot> createModelSubscription<T extends FirestoreModel>({
  OrderedMap<String, T>collection,
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
    }
  );
}

abstract class StoredProperty<T> extends Property<T> {

  void readFrom(Map<dynamic, dynamic> data);

  void writeTo(Map<dynamic, dynamic> data);

}


class Attribute<T> implements StoredProperty<T> {

  final String _name;
  final DataProperty<T> attr;

  Attribute(this._name, this.attr);

  get name => _name;

  @override
  bool get changed => attr.changed;

  @override
  set changed(bool c) {
    attr.changed = c;
  }

  @override
  T get value => attr.value;

  @override
  set value(v) {
    attr.value = v;
  }
  
  @override
  get oldValue => attr.oldValue;  

  @override
  void copyFrom(Property<T> other) {
    attr.copyFrom(other is Attribute<T> ? other.attr: other);
  }

  @override
  bool equals(Property<T> other) {
    return attr.equals(other is Attribute<T> ? other.attr: other);
  }  

  @override
  void readFrom(Map<dynamic, dynamic> data) {
    if(!data.containsKey(_name)) {
      attr.data = null;
    } else {
      var attrData = data[_name];
      attr.data = attrData;
    }
  }

  @override
  void writeTo(Map<dynamic, dynamic> data) {
    data[_name] = attr.data;
  }

  bool get isNull => attr.data == null;
  
  Query whereEquals(Query src) {
    return src.where(_name, isEqualTo: attr.data);
  }

  Query whereLessThan(Query src) {
    return src.where(_name, isLessThan: attr.data);
  }

  Query orderBy(Query src, {descending: false}) {
    return src.orderBy(_name, descending: descending);
  }

  Query startAt(Query src) {
    return src.startAt([attr.data]);
  }

  Query startAfter(Query src) {
    return src.startAfter([attr.data]);
  }

  Query endBefore(Query src) {
    return src.endBefore([attr.data]);
  }

  Query endAt(Query src) {
    return src.endAt([attr.data]);
  }
}


typedef DataProperty<T> AttributeFactory<T>();

class ListAttribute<T> implements StoredProperty<List<T>> {

  final String _prefix;
  AttributeFactory<T> factory;
  List<DataProperty<T>> _list = List<DataProperty<T>>();
  List<T> _oldValue;
  bool _changed = false;

  ListAttribute(this._prefix, this.factory);

  get name => _prefix;

  get changed => _changed || _list.length > 0 ? _list.map((attr) => attr.changed).reduce((a, b) => a || b) : false;

  set changed(c) {
    if(!c) {
      this._changed = false;
      for(var attr in _list)
        attr.changed = false;
    }
  }

  void append(T value) {
    var attr = factory();
    attr.value = value;
    _list.add(attr);
    _changed = true;
  }

  @override
  List<T> get value => _list.map((el) => el.value).toList();

  @override
  set value(List<T> value) {
    _oldValue = value;
    _list = value.map((el) => factory()..value = el).toList();
    _changed = true;
  }

  @override
  get oldValue {
    return _changed ? _oldValue: value;
  }
  
  @override
  void readFrom(Map<dynamic, dynamic> data) {
    while(true) {
      var key = '$_prefix${_list.length}';
      if(!data.containsKey(key))
        break;
      var attr = factory();
      attr.data = data[key];
      _list.add(attr);
      _changed = true;
    }
  }

  @override
  void writeTo(Map<dynamic, dynamic> data) {
    for(var i = 0; i < _list.length; i++) {
      var key = '$_prefix$i';
      data[key] = _list[i].data;
    }
  }

  @override
  void copyFrom(Property<List<T>> other) {
    _changed = equals(other);
    _oldValue = _changed ? value: null;
    if(other is ListAttribute<T>) {
      _list = other._list.map((a) => factory()..copyFrom(a)).toList();
    } else {
      _list = other.value.map((v) => factory()..value = v).toList();
    }
  }

  @override
  bool equals(Property<List<T>> other) {
    if(other is ListAttribute<T>) {
      if(_list.length != other._list.length)
        return false;
      final it0 = _list.iterator;
      final it1 = other._list.iterator;
      while(it0.moveNext() && it1.moveNext()) {
        if(!it0.current.equals(it1.current))
          return false;
      }
      return true;
    } else {
      return false;
    }
  }

}

Map<String, dynamic> createData(List<StoredProperty> attrs) {
  final data = Map<String, dynamic>();
  for(var attr in attrs)
    attr.writeTo(data);
  return data;
}

final equality = DeepCollectionEquality.unordered();

Map<String, dynamic> getChanges(Map<String, dynamic> data, Map<String, dynamic> oldData) {
  if(oldData == null || oldData.length == 0)
    return data;
  final changes = Map.of(data)..removeWhere((k, v) {
    // this code is verbose for debugging
    if(!oldData.containsKey(k))
      return false;
    bool eq = equality.equals(v, oldData[k]);
    return eq;
  });
  return changes;
}


class TimestampProperty extends DataProperty<DateTime> {

  TimestampProperty([DateTime initialValue]) {
    if(initialValue != null)
      value = initialValue;
  }

  get value {
    if(data is FieldValue)
      return null; // Special handling for server timestamp
    if(data == null)
      return null;
    final ts = data as Timestamp;
    return DateTime.fromMicrosecondsSinceEpoch(ts.microsecondsSinceEpoch, isUtc: true);
  }

  set value(dt) {
    data = dt == null ? null : Timestamp.fromMicrosecondsSinceEpoch(dt.toUtc().microsecondsSinceEpoch);
  }

  void setServerTimestamp() {
    data = FieldValue.serverTimestamp();
  }

}

class TimestampAttr extends Attribute<DateTime> {

  TimestampAttr(String name, [DateTime initialValue]): super(name, TimestampProperty(initialValue));

  void setServerTimestamp() {
    (attr as TimestampProperty).setServerTimestamp();
  }

}

/// Stores GeoPoint value as-is
class GeoPointProp extends DataProperty<GeoPoint> {

  GeoPointProp([GeoPoint initialValue]): super(initialValue);

}

/// Stores a document reference
class DocRefProp extends DataProperty<DocumentReference> {

  final CollectionReference collectionRef;

  DocRefProp(this.collectionRef, [DocumentReference initialValue]) {
    if(initialValue != null)
      value = initialValue;
  }

  @override
  DocumentReference dataToValue(data) {
    if(data is String)
      return collectionRef.document(data);
    else if(data is DocumentReference)
      return data;
    else
      return null;
  }

  @override
  valueToData(DocumentReference dr) {
    if(dr == null)
      return null;
    else {
      assert(dr.path.startsWith(collectionRef.path));
//      data = dr.documentID;
      return dr;
    }
  }

}


/// Stores the entire model as a value. Does not store model's ID
abstract class FirestoreModelProp<M extends FirestoreModel> extends MapProp<M> {
  
  M createModel();

  List<StoredProperty> getStoredAttrs(M model) => model.attrs;
  
  @override
  dataToValue(data) {
    if(data == null) {
      return null;
    } else {
      M model = createModel();
      model.readFrom(Map.castFrom<dynamic, dynamic, String, dynamic>(data));
      return model;
    }
  }

  @override
  valueToData(M model) {
    if(model == null) {
      return null;
    } else {
      final data = Map<String, dynamic>();
      model.writeTo(data);
      return data;
    }
  }
  
}
