function normalizeDocument(result) {
  if (!result) return null;
  if (Array.isArray(result.data)) return result.data[0] || null;
  return result.data || null;
}

class DocumentStore {
  constructor(database, collectionName = "esheep_identity", transactionRoot = database) {
    this.database = database;
    this.transactionRoot = transactionRoot;
    this.collectionName = collectionName;
    this.collection = database.collection(collectionName);
  }

  async get(documentID) {
    try {
      return normalizeDocument(await this.collection.doc(documentID).get());
    } catch (error) {
      if (error?.code === "DOCUMENT_NOT_FOUND" || error?.code === "DATABASE_REQUEST_FAILED" && /not found/i.test(String(error?.message || ""))) {
        return null;
      }
      throw error;
    }
  }

  async set(documentID, value) {
    await this.collection.doc(documentID).set({ ...value, _documentID: documentID });
    return value;
  }

  async update(documentID, value) {
    await this.collection.doc(documentID).update(value);
  }

  async remove(documentID) {
    await this.collection.doc(documentID).remove();
  }

  async find(where, limit = 1000) {
    const result = await this.collection.where(where).limit(limit).get();
    return result.data || [];
  }

  async transaction(operation) {
    return this.transactionRoot.runTransaction(async (transaction) => operation(new DocumentStore(transaction, this.collectionName, this.transactionRoot)));
  }

  async increment(documentID, field, amount) {
    await this.collection.doc(documentID).update({ [field]: this.transactionRoot.command.inc(amount) });
  }
}

module.exports = { DocumentStore, normalizeDocument };
